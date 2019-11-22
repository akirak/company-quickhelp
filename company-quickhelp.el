;;; company-quickhelp.el --- Popup documentation for completion candidates

;; Copyright (C) 2016, Lars Andersen

;; Author: Lars Andersen <expez@expez.com>
;; URL: https://www.github.com/expez/company-quickhelp
;; Keywords: company popup documentation quickhelp
;; Version: 2.2.0
;; Package-Requires: ((emacs "24.3") (company "0.8.9") (pos-tip "0.4.6"))

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; When idling on a completion candidate the documentation for the
;; candidate will pop up after `company-quickhelp-idle-delay' seconds.

;;; Usage:
;;  put (company-quickhelp-mode) in your init.el to activate
;;  `company-quickhelp-mode'.

;; You can adjust the time it takes for the documentation to pop up by
;; changing `company-quickhelp-delay'

;;; Code:
(require 'company)
(require 'pos-tip)
(require 'cl-lib)

(defgroup company-quickhelp nil
  "Documentation popups for `company-mode'"
  :group 'company)

(defconst company-quickhelp-buffer "*company quickhelp*")

(defcustom company-quickhelp-use-propertized-text nil
  "Allow the text to have properties like color, font size, etc."
  :type '(choice (boolean :tag "Allow"))
  :group 'company-quickhelp)

(defcustom company-quickhelp-delay 0.5
  "Delay, in seconds, before the quickhelp popup appears.

If set to nil the popup won't automatically appear, but can still
be triggered manually using `company-quickhelp-show'."
  :type '(choice (number :tag "Delay in seconds")
                 (const :tag "Don't popup help automatically" nil))
  :group 'company-quickhelp)

(defcustom company-quickhelp-max-lines nil
  "When not NIL, limits the number of lines in the popup."
  :type '(choice (integer :tag "Max lines to show in popup")
                 (const :tag "Don't limit the number of lines shown" nil))
  :group 'company-quickhelp)

(defcustom company-quickhelp-color-foreground nil
  "Popup text foreground color."
  :type '(choice (color)
                 (const :tag "Default" nil))
  :group 'company-quickhelp)

(defcustom company-quickhelp-color-background nil
  "Popup text background color."
  :type '(choice (color)
                 (const :tag "Default" nil))
  :group 'company-quickhelp)

(defvar-local company-quickhelp--timer nil
  "Quickhelp idle timer.")

(defvar-local company-quickhelp--original-tooltip-width company-tooltip-minimum-width
  "The documentation popup breaks inexplicably when we transition
  from a large pseudo-tooltip to a small one.  We solve this by
  overriding `company-tooltip-minimum-width' and save the
  original value here so we can restore it.")

(defun company-quickhelp-frontend (command)
  "`company-mode' front-end showing documentation in a `pos-tip' popup."
  (pcase command
    (`post-command (when company-quickhelp-delay
                     (company-quickhelp--set-timer)))
    (`hide
     (when company-quickhelp-delay
       (company-quickhelp--cancel-timer))
     (company-quickhelp--hide))))

(defun company-quickhelp--skip-footers-backwards ()
  "Skip backwards over footers and blank lines."
  (beginning-of-line)
  (while (and (not (= (point-at-eol) (point-min)))
              (or
               ;; [back] appears at the end of the help elisp help buffer
               (looking-at-p "\\[back\\]")
               ;; [source] cider's help buffer contains a link to source
               (looking-at-p "\\[source\\]")
               (looking-at-p "^\\s-*$")))
    (forward-line -1)))

(defun company-quickhelp--goto-max-line ()
  "Go to last line to display in popup."
  (if company-quickhelp-max-lines
      (forward-line company-quickhelp-max-lines)
    (goto-char (point-max))))

(defun company-quickhelp--docstring-from-buffer (start)
  "Fetch docstring from START."
  (goto-char start)
  (company-quickhelp--goto-max-line)
  (let ((truncated (< (point-at-eol) (point-max))))
    (company-quickhelp--skip-footers-backwards)
    (list :doc (buffer-substring start (point-at-eol))
          :truncated truncated)))

(defun company-quickhelp--completing-read (prompt candidates &rest rest)
  "`cider', and probably other libraries, prompt the user to
resolve ambiguous documentation requests.  Instead of failing we
just grab the first candidate and press forward."
  (car candidates))

(defun company-quickhelp--fetch-docstring (backend)
  "Fetch docstring from BACKEND."
  (let ((quickhelp-str (company-call-backend 'quickhelp-string backend)))
    (if (stringp quickhelp-str)
        (with-temp-buffer
          (insert quickhelp-str)
          (company-quickhelp--docstring-from-buffer (point-min)))
      (let ((doc (company-call-backend 'doc-buffer backend)))
        (when doc
          ;; The company backend can either return a buffer with the doc or a
          ;; cons containing the doc buffer and a position at which to start
          ;; reading.
          (let* ((doc-buffer (if (consp doc) (car doc) doc))
                 (doc-begin (when (consp doc) (cdr doc)))
                 (docstring (with-current-buffer doc-buffer
                              (company-quickhelp--docstring-from-buffer (or doc-begin (point-min))))))
            (kill-buffer doc-buffer)
            docstring))))))

(defun company-quickhelp--doc (selected)
  (cl-letf (((symbol-function 'completing-read)
             #'company-quickhelp--completing-read))
    (let* ((doc-and-meta (company-quickhelp--fetch-docstring selected))
           (truncated (plist-get doc-and-meta :truncated))
           (doc (plist-get doc-and-meta :doc)))
      (unless (member doc '(nil ""))
        (if truncated
            (concat doc "\n\n[...]")
          doc)))))

(defun company-quickhelp-manual-begin ()
  "Manually trigger the `company-quickhelp' popup for the
currently active `company' completion candidate."
  (interactive)
  ;; This might seem a bit roundabout, but when I attempted to call
  ;; `company-quickhelp--show' in a more direct manner it triggered a
  ;; redisplay of company's list of completion candidates which looked
  ;; quite weird.
  (let ((company-quickhelp-delay 0.01))
    (company-quickhelp--set-timer)))

(defun company-quickhelp--hide (&optional arg)
  (if (and company-quickhelp-window-to-delete
           (window-live-p company-quickhelp-window-to-delete))
      (delete-window company-quickhelp-window-to-delete)
    (when-let ((window (get-buffer-window company-quickhelp-buffer)))
      (quit-window nil window))))

(defvar company-quickhelp-window-to-delete nil)

(defun company-quickhelp--show ()
  (company-quickhelp--cancel-timer)
  (let* ((selected (nth company-selection company-candidates))
         (doc (let ((inhibit-message t))
                (company-quickhelp--doc selected)))
         (buffer (get-buffer-create company-quickhelp-buffer))
         (col-row (posn-actual-col-row (posn-at-point (point))))
         (row (cdr col-row))
         (remaining-rows (- (window-height) 14 row)))
    (unless (get-buffer-window buffer)
      (cond
       ((< remaining-rows 20)
        (let ((window (display-buffer-use-some-window buffer nil)))
          (set-window-dedicated-p window t)))
       (t
        (let ((window (display-buffer-below-selected
                       buffer `((window-height . ,remaining-rows)))))
          (set-window-dedicated-p window t)
          (setq company-quickhelp-window-to-delete window)))))
    (if doc
        (ignore-errors
          (with-current-buffer buffer
            (erase-buffer)
            (insert doc)
            (goto-char (point-min))))
      (company-quickhelp--hide))))

(defun company-quickhelp--set-timer ()
  (when (or (null company-quickhelp--timer)
            (eq this-command #'company-quickhelp-manual-begin))
    (setq company-quickhelp--timer
          (run-with-idle-timer company-quickhelp-delay nil
                               'company-quickhelp--show))))

(defun company-quickhelp--cancel-timer ()
  (when (timerp company-quickhelp--timer)
    (cancel-timer company-quickhelp--timer)
    (setq company-quickhelp--timer nil)))

(defun company-quickhelp-hide ()
  (company-cancel))

(defun company-quickhelp--enable ()
  (add-hook 'focus-out-hook #'company-quickhelp-hide nil t)
  (setq-local company-quickhelp--original-tooltip-width company-tooltip-minimum-width)
  (setq-local company-tooltip-minimum-width (max company-tooltip-minimum-width 40))
  (add-hook 'company-after-completion-hook 'company-quickhelp--hide)
  (make-local-variable 'company-frontends)
  (add-to-list 'company-frontends 'company-quickhelp-frontend :append))

(defun company-quickhelp--disable ()
  (remove-hook 'focus-out-hook #'company-quickhelp-hide t)
  (company-quickhelp--cancel-timer)
  (remove-hook 'company-after-completion-hook 'company-quickhelp--hide)
  (setq-local company-tooltip-minimum-width company-quickhelp--original-tooltip-width)
  (setq-local company-frontends (delq 'company-quickhelp-frontend company-frontends)))

;;;###autoload
(define-minor-mode company-quickhelp-local-mode
  "Provides documentation popups for `company-mode' using `pos-tip'."
  :global nil
  (if company-quickhelp-local-mode
      (company-quickhelp--enable)
    (company-quickhelp--disable)))

;;;###autoload
(define-globalized-minor-mode company-quickhelp-mode
  company-quickhelp-local-mode company-quickhelp-local-mode)

(provide 'company-quickhelp)

;;; company-quickhelp.el ends here
