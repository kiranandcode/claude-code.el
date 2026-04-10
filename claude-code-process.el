;;; claude-code-process.el --- Backend process management for claude-code.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Python backend process lifecycle: UV environment setup, process
;; start/stop, JSON-lines communication, and process filter/sentinel.

;;; Code:

(require 'claude-code-vars)

;; Forward declarations for functions defined in files loaded after this one.
(declare-function claude-code--handle-event "claude-code-events")
(declare-function claude-code--schedule-render "claude-code-events")
(declare-function claude-code--agent-update "claude-code-agents")
(declare-function claude-code--stop-thinking "claude-code-render")
(declare-function claude-code-tools-mcp-server-start "claude-code-emacs-tools")

(defun claude-code--python-dir ()
  "Return the path to the python/ subdirectory."
  (expand-file-name "python/" claude-code--package-dir))

(defun claude-code--uv-available-p ()
  "Return non-nil if the configured Python command is on PATH."
  (executable-find claude-code-python-command))

(defun claude-code--venv-ready-p ()
  "Return non-nil if the Python virtual environment exists."
  (file-directory-p
   (expand-file-name ".venv" (claude-code--python-dir))))

(defun claude-code--run-uv-sync ()
  "Run `uv sync' in the python directory.
Shows output in *claude-code-setup* on failure."
  (message "claude-code: running uv sync...")
  (let* ((default-directory (claude-code--python-dir))
         (buf (get-buffer-create "*claude-code-setup*")))
    (with-current-buffer buf (erase-buffer))
    (let ((result (call-process claude-code-python-command nil buf nil "sync")))
      (if (= result 0)
          (progn
            (when (get-buffer-window buf)
              (delete-window (get-buffer-window buf)))
            (kill-buffer buf)
            (message "claude-code: Python environment ready."))
        (pop-to-buffer buf)
        (user-error
         "claude-code: `uv sync' failed (exit %d).  See *claude-code-setup*"
         result)))))

(defun claude-code--ensure-environment ()
  "Ensure uv is installed and the Python venv is ready.
Signals an error if uv is not found.  Runs `uv sync' if the
virtual environment does not exist yet."
  (unless (claude-code--uv-available-p)
    (user-error
     "claude-code: `%s' not found.  Install uv: https://docs.astral.sh/uv/"
     claude-code-python-command))
  (unless (claude-code--venv-ready-p)
    (claude-code--run-uv-sync)))

;;;###autoload
(defun claude-code-sync ()
  "Force-sync the Python environment by running `uv sync'."
  (interactive)
  (unless (claude-code--uv-available-p)
    (user-error
     "claude-code: `%s' not found.  Install uv: https://docs.astral.sh/uv/"
     claude-code-python-command))
  (claude-code--run-uv-sync))

(defun claude-code--backend-script ()
  "Return the path to the Python backend script."
  (expand-file-name "python/claude_code_backend.py"
                    claude-code--package-dir))

(defun claude-code--start-process ()
  "Start the Python backend process.
Ensures the Python environment is set up before launching, and starts
the persistent MCP socket server so the backend can reach Emacs without
forking `emacsclient' for every tool call."
  (claude-code--ensure-environment)
  (when (and claude-code--process
             (process-live-p claude-code--process))
    (delete-process claude-code--process))
  ;; Start (or reuse) the persistent MCP socket server and pass its path
  ;; to the Python backend via env var.  Falls back gracefully to the
  ;; emacsclient subprocess transport if the server can't start.
  (let* ((mcp-socket-path
          (condition-case err
              (claude-code-tools-mcp-server-start)
            (error
             (message "claude-code: MCP socket server failed to start (%s); \
falling back to emacsclient" (error-message-string err))
             nil)))
         (process-environment
          (if mcp-socket-path
              (cons (format "CLAUDE_CODE_MCP_SOCKET=%s" mcp-socket-path)
                    process-environment)
            process-environment))
         ;; Do NOT clear claude-code--session-id here.  The backend's
         ;; handle_query already retries without resume on failure, so a
         ;; stale ID is safe and preserving it lets claude-code-reload
         ;; resume the conversation.
         (default-directory (expand-file-name "python/" claude-code--package-dir))
         (buf (current-buffer))
         (proc (make-process
                :name (format "claude-sdk-%s" (buffer-name buf))
                :command (list claude-code-python-command
                               "run" "python3"
                               (claude-code--backend-script))
                :filter (lambda (_proc output)
                          (claude-code--process-filter buf output))
                :sentinel (lambda (_proc event)
                            (claude-code--process-sentinel buf event))
                :coding 'utf-8-unix
                :connection-type 'pipe
                :noquery t)))
    (setq claude-code--process proc)
    (setq claude-code--status 'starting)))

(defun claude-code--stop-process ()
  "Stop the backend process."
  (claude-code--stop-thinking)
  (when (and claude-code--process
             (process-live-p claude-code--process))
    ;; Silence the sentinel so an intentional stop doesn't append a
    ;; spurious "Backend process exited" info message.
    (set-process-sentinel claude-code--process #'ignore)
    (claude-code--send-json '((type . "quit")))
    (sit-for 0.1)
    (when (process-live-p claude-code--process)
      (delete-process claude-code--process)))
  (setq claude-code--process nil)
  (setq claude-code--status 'stopped))

(defun claude-code--send-json (data)
  "Send DATA (an alist) as a JSON line to the backend.
If the process is dead, restart it automatically before sending."
  (unless (and claude-code--process
               (process-live-p claude-code--process))
    (message "claude-code: backend not running, restarting...")
    (claude-code--start-process)
    ;; Wait for the process to emit the initial "ready" status.
    (let ((waited 0))
      (while (and (< waited 5)
                  (not (eq claude-code--status 'ready)))
        (sit-for 0.5)
        (cl-incf waited 0.5))))
  (when (and claude-code--process
             (process-live-p claude-code--process))
    (process-send-string
     claude-code--process
     (concat (json-encode data) "\n"))))

(defun claude-code--process-filter (buf output)
  "Handle OUTPUT from the backend for display buffer BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq claude-code--partial-line
            (concat claude-code--partial-line output))
      (let ((lines (split-string claude-code--partial-line "\n")))
        (setq claude-code--partial-line (car (last lines)))
        (dolist (line (butlast lines))
          (when (and line (not (string-empty-p line)))
            (if (not (eq (aref line 0) ?{))
                ;; Not JSON — log it but don't crash
                (message "Claude SDK: non-JSON line: %S"
                         (substring line 0 (min 200 (length line))))
              (condition-case err
                  (claude-code--handle-event
                   (json-parse-string line :object-type 'alist :false-object nil))
                (error
                 (message "Claude SDK: parse error on: %S — %s"
                          (substring line 0 (min 200 (length line)))
                          (error-message-string err)))))))))))

(defun claude-code--process-sentinel (buf event)
  "Handle process EVENT for display buffer BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (unless (string-match-p "open" event)
        (setq claude-code--status 'stopped)
        (setq claude-code--process nil)
        (claude-code--stop-thinking)
        (when-let ((key (claude-code--effective-session-key)))
          (claude-code--agent-update key :status 'stopped))
        (push `((type . "info")
                (text . ,(format "Backend process exited: %s  Press R to restart."
                                 (string-trim event))))
              claude-code--messages)
        (claude-code--schedule-render)))))

(provide 'claude-code-process)
;;; claude-code-process.el ends here
