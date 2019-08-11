(defvar floyd-mode-name "Floyd")
(defvar-local floyd-process nil)

(defun floyd-restart ()
  (interactive)
  (let ((process-name "floyd")
        (buffer "*floyd*")
        (program "floyd"))
    (when floyd-process
      (setq buffer (process-buffer floyd-process))
      (floyd-stop)
      (with-current-buffer buffer
        (erase-buffer)))
    (let ((process-connection-type nil))
      (setq floyd-process (start-process process-name buffer program))
      (setq mode-name (format "*%s*" floyd-mode-name))
      (force-mode-line-update))))

(defun floyd-send (string)
  (interactive "s")
  (when floyd-process
    (process-send-string floyd-process string)))

(defun floyd-send-region ()
  (interactive)
  (when floyd-process
    (let ((start (mark))
          (end (point)))
      (when (and start end)
        (when (< end start)
          (let ((tmp end))
            (setq end start)
            (setq start tmp)))
        (process-send-region floyd-process start end)))))

(defun floyd-send-buffer ()
  (interactive)
  (floyd-send (buffer-string)))

(defun floyd-send-line ()
  (interactive)
  (save-mark-and-excursion
    (beginning-of-line)
    (let ((beg (point)))
      (forward-line 1)
      (when (> (point) beg)
        (floyd-send (buffer-substring beg (point)))))))

(defun floyd-stop ()
  (interactive)
  (when (and floyd-process
             (eq (process-status floyd-process) 'run))
    (process-send-string floyd-process "quit\n"))
  (setq floyd-process nil)
  (setq mode-name floyd-mode-name)
  (force-mode-line-update))

(defun floyd-start-or-stop ()
  (interactive)
  (if floyd-process
      (floyd-stop)
    (floyd-restart)))

(defun floyd-find-top-definition ()
  (let (start end)
    (save-mark-and-excursion
      (when (beginning-of-defun)
        (setq start (point)))
      (when start
        (goto-char start)
        (end-of-defun)
        (setq end (point))))
    (when (and start end)
      (buffer-substring-no-properties start end))))

(defun floyd-get-definition-name (definition)
  (when (string-match defun-prompt-regexp definition)
    (match-string-no-properties 1 definition)))

(defun floyd-send-eval-top-definition ()
  (interactive)
  (let* ((top-definition (floyd-find-top-definition))
         (name (floyd-get-definition-name top-definition)))
    (when (and top-definition name)
      (floyd-send top-definition)
      (floyd-send name)
      (floyd-send "\n"))))

(defvar floyd-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?# "<" st)
    (modify-syntax-entry ?\n ">" st)
    (modify-syntax-entry ?\" "\"" st)
    (modify-syntax-entry ?{ "(}" st)
    (modify-syntax-entry ?} "){" st)
    (modify-syntax-entry ?~ "_" st)
    (modify-syntax-entry ?> "_" st)
    (modify-syntax-entry ?+ "_" st)
    (modify-syntax-entry ?' "_" st)
    (modify-syntax-entry ?` "_" st)
    st)
  "Syntax table for `floyd-mode'.")

(defvar floyd-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-s") 'floyd-start-or-stop)
    (define-key map (kbd "C-c C-a") 'floyd-send-buffer)
    (define-key map (kbd "C-c C-r") 'floyd-send-region)
    (define-key map (kbd "C-c C-l") 'floyd-send-line)
    (define-key map (kbd "C-c C-c") 'floyd-send-eval-top-definition)
    map)
  "Keymap for `floyd-mode'.")

(defvar floyd-keywords
  `(("\\_<\\$[a-zA-Z0-9:_-]+\\_>" . font-lock-variable-name-face)
    ("-?[0-9]+\\(\\.[0-9]+\\)?['`^_+-]?\\_>" . font-lock-constant-face)
    ("-?[0-9]+/[0-9]+\\_>" . font-lock-constant-face)
    ("\\_<[cdefgab][0-9]['`^_]\\_>" . font-lock-constant-face)
    ,(regexp-opt '("sfload" "channel" "sf" "bank" "program" "bpm" "dur" "delta" "wait" "root" "scale" "semitones" "degrees" "vel" "shift" "let" "rep" "sched" "quit") 'symbols)
    "\\_<[~>v+@wtC]"))

(define-derived-mode floyd-mode
  prog-mode floyd-mode-name
  "Major mode for editing Floyd scripts."
  (setq-local font-lock-defaults '(floyd-keywords))
  (setq-local defun-prompt-regexp "^let\\s-+\\(\\$\\w+\\)\\s-+"))

(provide 'floyd-mode)
