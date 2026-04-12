;;; claude-code-xwidget.el --- xwidget-webkit preview for HTML/SVG tool output -*- lexical-binding: t; -*-

;;; Commentary:
;; When a Bash or Write tool result contains HTML or SVG content, render
;; it in a split window via xwidget-webkit.  Adds a [render] button
;; alongside the existing [view] button in tool result headings.

;;; Code:

(require 'cl-lib)

;; Conditional require — xwidget may not be compiled in.
(declare-function xwidget-webkit-mode "xwidget")
(declare-function xwidget-webkit-current-session "xwidget")
(declare-function xwidget-webkit-execute-script "xwidget")
(declare-function make-xwidget "xwidget")
(declare-function xwidget-webkit-goto-uri "xwidget")

;;;; Customization

(defcustom claude-code-xwidget-preview-enabled t
  "When non-nil, show a [render] button for HTML/SVG tool results.
Requires Emacs compiled with xwidget-webkit support and a graphical frame."
  :type 'boolean
  :group 'claude-code)

(defcustom claude-code-xwidget-preview-width 80
  "Width in columns for the xwidget preview window."
  :type 'integer
  :group 'claude-code)

(defcustom claude-code-xwidget-preview-height 20
  "Height in lines for the xwidget preview window."
  :type 'integer
  :group 'claude-code)

;;;; HTML/SVG detection

(defun claude-code-xwidget--html-p (text)
  "Return non-nil if TEXT looks like HTML content."
  (and (stringp text)
       (> (length text) 20)
       (string-match-p
        "\\(?:<!DOCTYPE html\\|<html\\b\\|<head>\\|<body>\\)"
        (substring text 0 (min 500 (length text))))))

(defun claude-code-xwidget--svg-p (text)
  "Return non-nil if TEXT looks like SVG content."
  (and (stringp text)
       (> (length text) 10)
       (string-match-p "<svg\\b" (substring text 0 (min 500 (length text))))))

(defun claude-code-xwidget--renderable-p (text)
  "Return non-nil if TEXT contains HTML or SVG that can be rendered."
  (and claude-code-xwidget-preview-enabled
       (display-graphic-p)
       (featurep 'xwidget-internal)
       (or (claude-code-xwidget--html-p text)
           (claude-code-xwidget--svg-p text))))

;;;; Preview rendering

(defun claude-code-xwidget--preview (content)
  "Open CONTENT (HTML or SVG string) in an xwidget-webkit preview window."
  (unless (featurep 'xwidget-internal)
    (user-error "This Emacs was not built with xwidget-webkit support"))
  (let* ((buf-name "*Claude HTML Preview*")
         (buf (get-buffer-create buf-name))
         (html (claude-code-xwidget--wrap-content content))
         ;; URL-encode the HTML as a data: URI
         (uri (concat "data:text/html;charset=utf-8,"
                      (url-hexify-string html))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer))
      ;; Create or reuse xwidget session
      (if (and (fboundp 'xwidget-webkit-mode)
               (fboundp 'xwidget-webkit-current-session))
          (progn
            (unless (eq major-mode 'xwidget-webkit-mode)
              (xwidget-webkit-mode))
            (if-let ((session (xwidget-webkit-current-session)))
                (xwidget-webkit-goto-uri session uri)
              ;; No session yet — need to create one via new-session
              (claude-code-xwidget--new-session buf uri)))
        (claude-code-xwidget--new-session buf uri)))
    ;; Display in a side window
    (display-buffer buf
                    `((display-buffer-in-side-window)
                      (side . right)
                      (window-width . ,claude-code-xwidget-preview-width)
                      (window-height . ,claude-code-xwidget-preview-height)))))

(defun claude-code-xwidget--new-session (buf uri)
  "Create a new xwidget-webkit session in BUF loading URI."
  (if (fboundp 'xwidget-webkit-new-session)
      (with-current-buffer buf
        (xwidget-webkit-new-session uri))
    ;; Fallback: browse-url
    (browse-url uri)))

(defun claude-code-xwidget--wrap-content (content)
  "Wrap CONTENT in a minimal HTML document if it's bare SVG or a fragment."
  (cond
   ;; Already a full HTML document
   ((claude-code-xwidget--html-p content)
    content)
   ;; SVG — wrap in HTML with centered layout
   ((claude-code-xwidget--svg-p content)
    (format "<!DOCTYPE html>
<html><head>
<style>
  body { margin: 0; display: flex; justify-content: center;
         align-items: center; min-height: 100vh;
         background: #1a1a2e; }
  svg { max-width: 100%%; max-height: 100vh; }
</style>
</head><body>
%s
</body></html>" content))
   ;; Unknown — wrap as preformatted text
   (t
    (format "<!DOCTYPE html>
<html><head>
<style>
  body { margin: 1em; font-family: monospace; white-space: pre-wrap;
         background: #1a1a2e; color: #e0e0e0; }
</style>
</head><body>%s</body></html>"
            (claude-code-xwidget--escape-html content)))))

(defun claude-code-xwidget--escape-html (text)
  "Escape HTML special characters in TEXT."
  (let ((s text))
    (setq s (replace-regexp-in-string "&" "&amp;" s))
    (setq s (replace-regexp-in-string "<" "&lt;" s))
    (setq s (replace-regexp-in-string ">" "&gt;" s))
    s))

;;;; Integration with render pipeline

(declare-function claude-code--splice-heading-button "claude-code-render")

(defun claude-code-xwidget-maybe-add-render-button (content)
  "If CONTENT is renderable HTML/SVG, splice a [render] button.
Call this immediately after `claude-code--splice-heading-button' for [view]."
  (when (claude-code-xwidget--renderable-p content)
    (claude-code--splice-heading-button
     "[render]" 'claude-code-action-button
     "Render HTML/SVG in xwidget-webkit"
     (lambda (_btn) (claude-code-xwidget--preview content)))))

(provide 'claude-code-xwidget)
;;; claude-code-xwidget.el ends here
