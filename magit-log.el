;;; magit-log.el --- inspect Git history

;; Copyright (C) 2010-2014  The Magit Project Developers
;;
;; For a full list of contributors, see the AUTHORS.md file
;; at the top-level directory of this distribution and at
;; https://raw.github.com/magit/magit/master/AUTHORS.md

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Maintainer: Jonas Bernoulli <jonas@bernoul.li>

;; Magit is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; Magit is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Magit.  If not, see http://www.gnu.org/licenses.

;;; Code:

(require 'magit-core)
(require 'magit-diff)

(defvar magit-commit-buffer-name-format)

(declare-function magit-blame-chunk-get 'magit-blame)
(declare-function magit-insert-status-headers 'magit)
(declare-function magit-show-commit 'magit)
(defvar magit-blame-mode)

(require 'ansi-color)

;;; Options
;;;; Log Mode

(defgroup magit-log nil
  "Inspect and manipulate Git history."
  :group 'magit-modes)

(defcustom magit-log-buffer-name-format "*magit-log: %a*"
  "Name format for buffers used to display log entries.

The following `format'-like specs are supported:
%a the absolute filename of the repository toplevel.
%b the basename of the repository toplevel."
  :package-version '(magit . "2.1.0")
  :group 'magit-log
  :type 'string)

(defcustom magit-log-auto-more nil
  "Insert more log entries automatically when moving past the last entry.
Only considered when moving past the last entry with
`magit-goto-*-section' commands."
  :group 'magit-log
  :type 'boolean)

(defcustom magit-log-cutoff-length 100
  "The maximum number of commits to show in the log and whazzup buffers."
  :group 'magit-log
  :type 'integer)

(defcustom magit-log-infinite-length 99999
  "Number of log used to show as maximum for `magit-log-cutoff-length'."
  :group 'magit-log
  :type 'integer)

(defcustom magit-log-format-graph-function nil
  "Function used to format graphs in log buffers.
The function is called with one argument, the propertized graph
of a single line in as a string.  It has to return the formatted
string.  This option can also be nil, in which case the graph is
inserted as is."
  :package-version '(magit . "2.1.0")
  :group 'magit-log
  :type '(choice (const :tag "insert as is" nil)
                 (function-item magit-log-format-unicode-graph)
                 function))

(defcustom magit-log-format-unicode-graph-alist
  '((?/ . ?╱) (?| . ?│) (?\\ . ?╲) (?* . ?◆) (?o . ?◇))
  "Alist used by `magit-log-format-unicode-graph' to translate chars."
  :package-version '(magit . "2.1.0")
  :group 'magit-log
  :type '(repeat (cons :format "%v\n"
                       (character :format "replace %v ")
                       (character :format "with %v"))))

(defcustom magit-log-show-margin t
  "Whether to initially show the margin in log buffers.

When non-nil the author name and date are initially displayed in
the margin of log buffers.  The margin can be shown or hidden in
the current buffer using the command `magit-log-toggle-margin'.

When a log buffer contains a verbose log, then the margin is
never displayed.  In status buffers this option is ignored but
it is possible to show the margin using the mentioned command."
  :package-version '(magit . "2.1.0")
  :group 'magit-log
  :type 'boolean)

(put 'magit-log-show-margin 'permanent-local t)

(defcustom magit-duration-spec
  `((?Y "year"   "years"   ,(round (* 60 60 24 365.2425)))
    (?M "month"  "months"  ,(round (* 60 60 24 30.436875)))
    (?w "week"   "weeks"   ,(* 60 60 24 7))
    (?d "day"    "days"    ,(* 60 60 24))
    (?h "hour"   "hours"   ,(* 60 60))
    (?m "minute" "minutes" 60)
    (?s "second" "seconds" 1))
  "Units used to display durations in a human format.
The value is a list of time units, beginning with the longest.
Each element has the form (CHAR UNIT UNITS SECONDS).  UNIT is the
time unit, UNITS is the plural of that unit.  CHAR is a character
abbreviation.  And SECONDS is the number of seconds in one UNIT.
Also see option `magit-log-margin-spec'."
  :package-version '(magit . "2.1.0")
  :group 'magit-log
  :type '(repeat (list (character :tag "Unit character")
                       (string    :tag "Unit singular string")
                       (string    :tag "Unit plural string")
                       (integer   :tag "Seconds in unit"))))

(defcustom magit-log-margin-spec '(28 7 magit-duration-spec)
  "How to format the log margin.

The log margin is used to display each commit's author followed
by the commit's age.  This option controls the total width of the
margin and how time units are formatted, the value has the form:

  (WIDTH UNIT-WIDTH DURATION-SPEC)

WIDTH specifies the total width of the log margin.  UNIT-WIDTH is
either the integer 1, in which case time units are displayed as a
single characters, leaving more room for author names; or it has
to be the width of the longest time unit string in DURATION-SPEC.
DURATION-SPEC has to be a variable, its value controls which time
units, in what language, are being used."
  :package-version '(magit . "2.1.0")
  :group 'magit-log
  :set-after '(magit-duration-spec)
  :type '(list (integer  :tag "Margin width")
               (choice   :tag "Time unit style"
                         (const   :format "%t\n"
                                  :tag "abbreviate to single character" 1)
                         (integer :format "%t\n"
                                  :tag "show full name" 7))
               (variable :tag "Duration spec variable")))

(defface magit-log-graph
  '((((class color) (background light)) :foreground "grey30")
    (((class color) (background  dark)) :foreground "grey80"))
  "Face for the graph part of the log output."
  :group 'magit-faces)

(defface magit-log-author
  '((((class color) (background light)) :foreground "firebrick")
    (((class color) (background  dark)) :foreground "tomato"))
  "Face for the author part of the log output."
  :group 'magit-faces)

(defface magit-log-date
  '((((class color) (background light)) :foreground "grey30")
    (((class color) (background  dark)) :foreground "grey80"))
  "Face for the date part of the log output."
  :group 'magit-faces)

;;;; Cherry Mode

(defcustom magit-cherry-buffer-name-format "*magit-cherry: %a*"
  "Name format for buffers used to display commits not merged upstream.

The following `format'-like specs are supported:
%a the absolute filename of the repository toplevel.
%b the basename of the repository toplevel."
  :group 'magit-modes
  :type 'string)

(defcustom magit-cherry-sections-hook
  '(magit-insert-cherry-headers
    magit-insert-cherry-commits)
  "Hook run to insert sections into the cherry buffer."
  :package-version '(magit . "2.1.0")
  :group 'magit-modes
  :type 'hook)

;;;; Reflog Mode

(defcustom magit-reflog-buffer-name-format "*magit-reflog: %a*"
  "Name format for buffers used to display reflog entries.

The following `format'-like specs are supported:
%a the absolute filename of the repository toplevel.
%b the basename of the repository toplevel."
  :package-version '(magit . "2.1.0")
  :group 'magit-modes
  :type 'string)

(defface magit-reflog-commit
  '((t :background "LemonChiffon1"
       :foreground "goldenrod4"))
  "Face for commit commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-amend
  '((t :inherit magit-reflog-commit))
  "Face for amend commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-merge
  '((t :inherit magit-reflog-commit))
  "Face for merge, checkout and branch commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-checkout
  '((((class color) (background light))
     :background "grey85"
     :foreground "LightSkyBlue4")
    (((class color) (background dark))
     :background "grey30"
     :foreground "LightSkyBlue1"))
  "Face for checkout commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-reset
  '((t :background "IndianRed1"
       :foreground "IndianRed4"))
  "Face for reset commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-rebase
  '((((class color) (background light))
     :background "grey85"
     :foreground "OliveDrab4")
    (((class color) (background dark))
     :background "grey30"
     :foreground "DarkSeaGreen2"))
  "Face for rebase commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-cherry-pick
  '((t :background "LightGreen"
       :foreground "DarkOliveGreen"))
  "Face for cherry-pick commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-remote
  '((t :background "grey50"))
  "Face for pull and clone commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-other
  '((t :background "grey50"))
  "Face for other commands in reflogs."
  :group 'magit-faces)

;;;; Log Sections

(defcustom magit-log-section-commit-count 10
  "How many recent commits to show in certain log sections.
How many recent commits `magit-insert-recent-commits' and
`magit-insert-unpulled-or-recent-commits' (provided there
are no unpulled commits) show."
  :package-version '(magit . "2.1.0")
  :group 'magit-status
  :type 'number)

(defcustom magit-log-section-args nil
  "Additional Git arguments used when creating log sections.
Only `--graph', `--decorate', and `--show-signature' are
supported.  This option is only a temporary kludge and will
be removed again.  Note that due to an issue in Git the
use of `--graph' is very slow with long histories.  See
http://www.mail-archive.com/git@vger.kernel.org/msg51337.html"
  :package-version '(magit . "2.1.0")
  :group 'magit-status
  :type '(repeat (choice (const "--graph")
                         (const "--decorate")
                         (const "--show-signature"))))

;;; Commands

(magit-define-popup magit-log-popup
  "Popup console for log commands."
  'magit-popups
  :man-page "git-log"
  :switches '((?m "Only merge commits"        "--merges")
              (?d "Date Order"                "--date-order")
              (?f "First parent"              "--first-parent")
              (?i "Case insensitive patterns" "-i")
              (?P "Pickaxe regex"             "--pickaxe-regex")
              (?g "Show Graph"                "--graph")
              (?S "Show Signature"            "--show-signature")
              (?D "Show ref names"            "--decorate")
              (?n "Name only"                 "--name-only")
              (?M "All match"                 "--all-match")
              (?A "All"                       "--all"))
  :options  '((?r "Relative"       "--relative="  read-directory-name)
              (?c "Committer"      "--committer=" read-from-minibuffer)
              (?> "Since"          "--since="     read-from-minibuffer)
              (?< "Before"         "--before="    read-from-minibuffer)
              (?a "Author"         "--author="    read-from-minibuffer)
              (?g "Grep messages"  "--grep="      read-from-minibuffer)
              (?G "Grep patches"   "-G"           read-from-minibuffer)
              (?L "Trace evolution of line range"
                  "-L" magit-read-file-trace)
              (?s "Pickaxe search" "-S"           read-from-minibuffer)
              (?b "Branches"       "--branches="  read-from-minibuffer)
              (?R "Remotes"        "--remotes="   read-from-minibuffer))
  :actions  '((?l "Oneline"        magit-log-dwim)
              (?L "Verbose"        magit-log-verbose-dwim)
              (?r "Reflog"         magit-reflog)
              (?f "File log"       magit-log-file)
              (?b "Oneline branch" magit-log)
              (?B "Verbose branch" magit-log-verbose)
              (?R "Reflog HEAD"    magit-reflog-head))
  :default-arguments '("--graph" "--decorate")
  :default-action 'magit-log-dwim
  :max-action-columns 4)

;;;###autoload
(defun magit-log (range &optional args)
  (interactive (magit-log-read-args nil nil))
  (magit-mode-setup magit-log-buffer-name-format nil
                    #'magit-log-mode
                    #'magit-refresh-log-buffer 'oneline range
                    (cl-delete "^-L" args :test 'string-match-p))
  (magit-log-goto-same-commit))

;;;###autoload
(defun magit-log-dwim (range &optional args)
  (interactive (magit-log-read-args t nil))
  (magit-log range args))

;;;###autoload
(defun magit-log-verbose (range &optional args)
  (interactive (magit-log-read-args nil t))
  (magit-mode-setup magit-log-buffer-name-format nil
                    #'magit-log-mode
                    #'magit-refresh-log-buffer 'long range args)
  (magit-log-goto-same-commit))

;;;###autoload
(defun magit-log-verbose-dwim (range &optional args)
  (interactive (magit-log-read-args t t))
  (magit-log-verbose range args))

(defun magit-log-read-args (dwim patch)
  (let ((default "HEAD"))
    (list (if (if dwim (not current-prefix-arg) current-prefix-arg)
              default
            (magit-read-rev (format "Show %s log for ref/rev/range"
                                    (if patch "verbose" "oneline"))
                            default))
          (if (--any? (string-match-p "^\\(-G\\|--grep=\\)" it)
                      magit-current-popup-args)
              (delete "--graph" magit-current-popup-args)
            magit-current-popup-args))))

;;;###autoload
(defun magit-log-file (file &optional use-graph)
  "Display the log for the currently visited file or another one.
With a prefix argument show the log graph."
  (interactive
   (list (magit-read-file-from-rev (magit-get-current-branch) "Log for file")
         current-prefix-arg))
  (magit-mode-setup magit-log-buffer-name-format nil
                    #'magit-log-mode
                    #'magit-refresh-log-buffer
                    'oneline "HEAD"
                    (cons "--follow"
                          (if use-graph
                              (cons "--graph" magit-current-popup-args)
                            (delete "--graph" magit-current-popup-args)))
                    file)
  (magit-log-goto-same-commit))

;;;###autoload
(defun magit-reflog (ref)
  "Display the reflog of the current branch.
With a prefix argument another branch can be chosen."
  (interactive (let ((branch (magit-get-current-branch)))
                 (if (and branch (not current-prefix-arg))
                     (list branch)
                   (list (magit-read-rev "Reflog of" branch)))))
  (magit-mode-setup magit-reflog-buffer-name-format nil
                    #'magit-reflog-mode
                    #'magit-refresh-reflog-buffer ref))

;;;###autoload
(defun magit-reflog-head ()
  "Display the HEAD reflog."
  (interactive)
  (magit-reflog "HEAD"))

(defun magit-log-toggle-margin ()
  "Show or hide the log margin."
  (interactive)
  (unless (derived-mode-p 'magit-log-mode 'magit-status-mode)
    (user-error "Buffer doesn't contain any logs"))
  (when (eq (car magit-refresh-args) 'long)
    (user-error "Log margin is redundant when showing verbose logs"))
  (magit-set-buffer-margin (not (cdr (window-margins)))))

(defun magit-log-show-more-entries (&optional arg)
  "Grow the number of log entries shown.

With no prefix optional ARG, show twice as many log entries.
With a numerical prefix ARG, add this number to the number of shown log entries.
With a non numeric prefix ARG, show all entries"
  (interactive "P")
  (setq-local magit-log-cutoff-length
              (cond ((numberp arg) (+ magit-log-cutoff-length arg))
                    (arg magit-log-infinite-length)
                    (t (* magit-log-cutoff-length 2))))
  (let ((old-point (point)))
    (magit-refresh)
    (goto-char old-point)))

(defun magit-read-file-trace (ignored)
  (let ((file  (magit-read-file-from-rev "HEAD" "File"))
        (trace (magit-read-string "Trace")))
    (if (string-match
         "^\\(/.+/\\|:[^:]+\\|[0-9]+,[-+]?[0-9]+\\)\\(:\\)?$" trace)
        (concat trace (or (match-string 2 trace) ":") file)
      (user-error "Trace is invalid, see man git-log"))))

;;; Log Mode

(defvar magit-log-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-mode-map)
    (define-key map "\C-c\C-b" 'magit-go-backward)
    (define-key map "\C-c\C-f" 'magit-go-forward)
    (define-key map "+" 'magit-log-show-more-entries)
    map)
  "Keymap for `magit-log-mode'.")

(define-derived-mode magit-log-mode magit-mode "Magit Log"
  "Mode for looking at Git log.
This mode is documented in info node `(magit)History'.

\\<magit-log-mode-map>\
Type \\[magit-refresh] to refresh the current buffer.
Type \\[magit-show-commit] or \\[magit-show-or-scroll-up]\
 to visit the commit at point.
Type \\[magit-merge-popup] to merge the commit at point.
Type \\[magit-cherry-pick] to cherry-pick the commit at point.
Type \\[magit-reset-head] to reset HEAD to the commit at point.
\n\\{magit-log-mode-map}"
  :group 'magit-log
  (magit-set-buffer-margin magit-log-show-margin))

(defun magit-refresh-log-buffer (style range args &optional file)
  (when (consp range)
    (setq range (concat (car range) ".." (cdr range))))
  (magit-insert-section (logbuf)
    (magit-insert-heading "Commits"
      (and file  (concat " for file " file))
      (and range (concat " in " range)))
    (if (eq style 'oneline)
        (magit-insert-log range args file)
      (magit-insert-log-long range args file)))
  (save-excursion
    (goto-char (point-min))
    (magit-format-log-margin)))

(defun magit-insert-log (range &optional args file)
  (--when-let (member "--decorate" args)
    (setcar it "--decorate=full"))
  (magit-git-wash (apply-partially 'magit-log-wash-log 'oneline)
    "log" (format "-%d" magit-log-cutoff-length) "--color"
    (format "--pretty=format:%%h%s %s[%%an][%%at]%%s"
            (if (member "--decorate=full" args) "%d" "")
            (if (member "--show-signature" args) "%G?" ""))
    (delete "--show-signature" args)
    range "--" file))

(defun magit-insert-log-long (range &optional args file)
  (--when-let (member "--decorate" args)
    (setcar it "--decorate=full"))
  (magit-git-wash (apply-partially 'magit-log-wash-log 'long)
    "log" (format "-%d" magit-log-cutoff-length)
    "--color" "--stat" "--abbrev-commit"
    args range "--" file))

(defvar magit-commit-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\r" 'magit-show-commit)
    (define-key map "a"  'magit-cherry-apply)
    (define-key map "v"  'magit-revert-no-commit)
    map)
  "Keymap for `commit' sections.")

(defvar magit-mcommit-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\r" 'magit-show-commit)
    map)
  "Keymap for `mcommit' (module commit) sections.")

(defconst magit-log-oneline-re
  (concat "^"
          "\\(?4:\\(?:[-_/|\\*o.] *\\)+ *\\)?"     ; graph
          "\\(?:"
          "\\(?1:[0-9a-fA-F]+\\) "                 ; sha1
          "\\(?:\\(?3:([^()]+)\\) \\)?"            ; refs
          "\\(?7:[BGUN]\\)?"                       ; gpg
          "\\[\\(?5:[^]]*\\)\\]"                   ; author
          "\\[\\(?6:[^]]*\\)\\]"                   ; date
          "\\(?2:.*\\)"                            ; msg
          "\\)?$"))

(defconst magit-log-long-re
  (concat "^"
          "\\(?4:\\(?:[-_/|\\*o.] *\\)+ *\\)?"     ; graph
          "\\(?:"
          "\\(?:commit \\(?1:[0-9a-fA-F]+\\)"      ; sha1
          "\\(?: \\(?3:([^()]+)\\)\\)?\\)"         ; refs
          "\\|"
          "\\(?2:.+\\)\\)$"))                      ; "msg"

(defconst magit-log-cherry-re
  (concat "^"
          "\\(?8:[-+]\\) "                         ; cherry
          "\\(?1:[0-9a-fA-F]+\\) "                 ; sha1
          "\\(?2:.*\\)$"))                         ; msg

(defconst magit-log-module-re
  (concat "^"
          "\\(?:\\(?11:[<>]\\) \\)?"               ; side
          "\\(?1:[0-9a-fA-F]+\\) "                 ; sha1
          "\\(?2:.*\\)$"))                         ; msg

(defconst magit-log-bisect-vis-re
  (concat "^"
          "\\(?1:[0-9a-fA-F]+\\) "                 ; sha1
          "\\(?:\\(?3:([^()]+)\\) \\)?"            ; refs
          "\\(?2:.+\\)$"))                         ; msg

(defconst magit-log-bisect-log-re
  (concat "^# "
          "\\(?3:bad:\\|skip:\\|good:\\) "         ; "refs"
          "\\[\\(?1:[^]]+\\)\\] "                  ; sha1
          "\\(?2:.+\\)$"))                         ; msg

(defconst magit-log-reflog-re
  (concat "^"
          "\\(?1:[^ ]+\\) "                        ; sha1
          "\\[\\(?5:[^]]*\\)\\] "                  ; author
          "\\(?6:[^ ]*\\) "                        ; date
          "[^@]+@{\\(?9:[^}]+\\)} "                ; refsel
          "\\(?10:merge\\|[^:]+\\)?:? ?"           ; refsub
          "\\(?2:.+\\)?$"))                        ; msg

(defconst magit-reflog-subject-re
  (concat "\\([^ ]+\\) ?"                          ; command (1)
          "\\(\\(?: ?-[^ ]+\\)+\\)?"               ; option  (2)
          "\\(?: ?(\\([^)]+\\))\\)?"))             ; type    (3)

(defvar magit-log-count nil)

(defun magit-log-wash-log (style args)
  (when (member "--color" args)
    (let ((ansi-color-apply-face-function
           (lambda (beg end face)
             (when face
               (put-text-property beg end 'font-lock-face face)))))
      (ansi-color-apply-on-region (point-min) (point-max))))
  (when (eq style 'cherry)
    (reverse-region (point-min) (point-max)))
  (let ((magit-log-count 0))
    (magit-wash-sequence (apply-partially 'magit-log-wash-line style
                                          (magit-abbrev-length)))
    (if (derived-mode-p 'magit-log-mode)
        (when (= magit-log-count magit-log-cutoff-length)
          (magit-insert-section (longer)
            (insert-text-button
             (substitute-command-keys
              (format "Type \\<%s>\\[%s] to show more history"
                      'magit-log-mode-map
                      'magit-log-show-more-entries))
             'action (lambda (button)
                       (magit-log-show-more-entries))
             'follow-link t
             'mouse-face 'magit-section-highlight)))
      (unless (equal (car args) "cherry")
        (insert ?\n)))))

(defun magit-log-wash-line (style abbrev)
  (looking-at (cl-ecase style
                (oneline magit-log-oneline-re)
                (long    magit-log-long-re)
                (cherry  magit-log-cherry-re)
                (module  magit-log-module-re)
                (reflog  magit-log-reflog-re)
                (bisect-vis magit-log-bisect-vis-re)
                (bisect-log magit-log-bisect-log-re)))
  (magit-bind-match-strings
      (hash msg refs graph author date gpg cherry refsel refsub side) nil
    (magit-delete-match)
    (when cherry
      (unless (derived-mode-p 'magit-cherry-mode)
        (insert "  "))
      (magit-insert cherry (if (string= cherry "-")
                               'magit-cherry-equivalent
                             'magit-cherry-unmatched) ?\s))
    (when side
      (magit-insert side (if (string= side "<")
                             'magit-diff-removed
                           'magit-diff-added) ?\s))
    (unless (eq style 'long)
      (when (eq style 'bisect-log)
        (setq hash (magit-git-string "rev-parse" "--short" hash)))
      (if hash
          (insert (propertize hash 'face 'magit-hash) ?\s)
        (insert (make-string (1+ abbrev) ? ))))
    (when graph
      (if magit-log-format-graph-function
          (insert (funcall magit-log-format-graph-function graph))
        (insert graph)))
    (when (and hash (eq style 'long))
      (magit-insert (if refs hash (magit-rev-parse hash)) 'magit-hash ?\s))
    (when refs
      (magit-insert (magit-format-ref-labels refs))
      (insert ?\s))
    (when refsub
      (insert (format "%-2s " refsel))
      (magit-insert (magit-log-format-reflog refsub)))
    (when msg
      (magit-insert msg (cl-case (and gpg (aref gpg 0))
                          (?G 'magit-signature-good)
                          (?B 'magit-signature-bad)
                          (?U 'magit-signature-untrusted))))
    (goto-char (line-beginning-position))
    (when (memq style '(oneline reflog))
      (magit-format-log-margin author date))
    (if hash
        (magit-insert-section it (commit hash)
          (when (eq style 'module)
            (setf (magit-section-type it) 'mcommit))
          (when (derived-mode-p 'magit-log-mode)
            (cl-incf magit-log-count))
          (forward-line)
          (when (eq style 'long)
            (magit-wash-sequence
             (lambda ()
               (looking-at magit-log-long-re)
               (when (match-string 2)
                 (magit-log-wash-line 'long abbrev))))))
      (forward-line)))
  t)

(defun magit-log-format-unicode-graph (string)
  "Translate ascii characters to unicode characters.
Whether that actually is an improvment depends on the unicode
support of the font in use.  The translation is done using the
alist in `magit-log-format-unicode-graph-alist'."
  (replace-regexp-in-string
   "[/|\\*o ]"
   (lambda (str)
     (propertize
      (string (or (cdr (assq (aref str 0)
                             magit-log-format-unicode-graph-alist))
                  (aref str 0)))
      'face (get-text-property 0 'face str)))
   string))

(defun magit-format-log-margin (&optional author date)
  (cl-destructuring-bind (width unit-width duration-spec)
      magit-log-margin-spec
    (if author
        (magit-make-margin-overlay
         (propertize (truncate-string-to-width
                      author (- width 1 3 ; gap, digits
                                (if (= unit-width 1) 1 (1+ unit-width))
                                (if (derived-mode-p 'magit-log-mode)
                                    1 ; pseudo fringe
                                  0))
                      nil ?\s (make-string 1 magit-ellipsis))
                     'face 'magit-log-author)
         " "
         (propertize (magit-format-duration
                      (abs (truncate (- (float-time)
                                        (string-to-number date))))
                      (symbol-value duration-spec)
                      unit-width)
                     'face 'magit-log-date)
         (when (derived-mode-p 'magit-log-mode)
           (propertize " " 'face 'fringe)))
      (magit-make-margin-overlay
       (propertize (make-string (1- width) ?\s) 'face 'default)
       (propertize " " 'face 'fringe)))))

(defun magit-format-duration (duration spec width)
  (cl-destructuring-bind (char unit units weight)
      (car spec)
    (let ((cnt (round (/ duration weight 1.0))))
      (if (or (not (cdr spec))
              (>= (/ duration weight) 1))
          (if (= width 1)
              (format "%3i%c" cnt char)
            (format (format "%%3i %%-%is" width) cnt
                    (if (= cnt 1) unit units)))
        (magit-format-duration duration (cdr spec) width)))))


(defun magit-log-maybe-show-more-entries (section)
  (when (and (eq (magit-section-type section) 'longer)
             magit-log-auto-more)
    (magit-log-show-more-entries)
    (forward-line -1)
    (magit-section-forward)))

(defun magit-log-maybe-show-commit (&optional section) ; TODO rename
  (--when-let
      (or (and section
               (eq (magit-section-type section) 'commit)
               (or (and (magit-diff-auto-show-p 'log-follow)
                        (get-buffer-window magit-commit-buffer-name-format))
                   (and (magit-diff-auto-show-p 'log-oneline)
                        (derived-mode-p 'magit-log-mode)
                        (eq (car magit-refresh-args) 'oneline)))
               (magit-section-value section))
          (and magit-blame-mode
               (magit-diff-auto-show-p 'blame-follow)
               (get-buffer-window magit-commit-buffer-name-format)
               (magit-blame-chunk-get :hash)))
    (magit-show-commit it t)))

(defun magit-log-goto-same-commit ()
  (--when-let
      (and magit-previous-section
           (derived-mode-p 'magit-log-mode)
           (-when-let (value (magit-section-value magit-previous-section))
             (--first (equal (magit-section-value it) value)
                      (magit-section-children magit-root-section))))
    (goto-char (magit-section-start it))))

;;; Select Mode

(defvar magit-log-select-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-log-mode-map)
    (define-key map "\C-c\C-b" 'undefined)
    (define-key map "\C-c\C-f" 'undefined)
    (define-key map "."        'magit-log-select-pick)
    (define-key map "\C-c\C-c" 'magit-log-select-pick)
    (define-key map "q"        'magit-log-select-quit)
    (define-key map "\C-c\C-k" 'magit-log-select-quit)
    map)
  "Keymap for `magit-log-select-mode'.")

(put 'magit-log-select-pick :advertised-binding [?\C-c ?\C-c])
(put 'magit-log-select-quit :advertised-binding [?\C-c ?\C-k])

(define-derived-mode magit-log-select-mode magit-log-mode "Magit Select"
  "Mode for selecting a commit from history."
  :group 'magit-log)

(defvar-local magit-log-select-pick-function nil)
(defvar-local magit-log-select-quit-function nil)

(defun magit-log-select (pick &optional quit desc branch args)
  (declare (indent defun))
  (magit-mode-setup magit-log-buffer-name-format nil
                    #'magit-log-select-mode
                    #'magit-refresh-log-buffer 'oneline
                    (or branch (magit-get-current-branch) "HEAD")
                    args)
  (magit-log-goto-same-commit)
  (setq magit-log-select-pick-function pick)
  (setq magit-log-select-quit-function quit)
  (message
   (substitute-command-keys
    (format "Type \\[%s] to select commit at point%s, or \\[%s] to abort"
            'magit-log-select-pick (if desc (concat " " desc) "")
            'magit-log-select-quit))))

(defun magit-log-select-pick ()
  (interactive)
  (let ((fun magit-log-select-pick-function)
        (rev (magit-commit-at-point)))
    (kill-buffer (current-buffer))
    (funcall fun rev)))

(defun magit-log-select-quit ()
  (interactive)
  (kill-buffer (current-buffer))
  (when magit-log-select-quit-function
    (funcall magit-log-select-quit-function)))

;;; Cherry Mode

(defvar magit-cherry-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-mode-map)
    map)
  "Keymap for `magit-cherry-mode'.")

(define-derived-mode magit-cherry-mode magit-mode "Magit Cherry"
  "Mode for looking at commits not merged upstream.

\\<magit-cherry-mode-map>\
Type \\[magit-show-commit] or \\[magit-show-or-scroll-up]\
 to visit the commit at point.
Type \\[magit-cherry-pick] to cherry-pick the commit at point.
\n\\{magit-cherry-mode-map}"
  :group 'magit-modes)

;;;###autoload
(defun magit-cherry (head upstream)
  "Show commits in a branch that are not merged in the upstream branch."
  (interactive
   (let  ((head (magit-read-rev "Cherry head" (magit-get-current-branch))))
     (list head (magit-read-rev "Cherry upstream"
                                (magit-get-tracked-branch head)))))
  (magit-mode-setup magit-cherry-buffer-name-format nil
                    #'magit-cherry-mode
                    #'magit-refresh-cherry-buffer upstream head))

(defun magit-refresh-cherry-buffer (upstream head)
  (magit-insert-section (cherry)
    (run-hooks 'magit-cherry-sections-hook)))

(defun magit-insert-cherry-headers ()
  (magit-insert-status-headers (nth 1 magit-refresh-args)
                               (nth 0 magit-refresh-args)))

(defun magit-insert-cherry-commits ()
  (magit-insert-section (cherries)
    (magit-insert-heading "Cherry commits:")
    (apply 'magit-insert-cherry-commits-1 magit-refresh-args)))

(defun magit-insert-cherry-commits-1 (&rest args)
  (magit-git-wash (apply-partially 'magit-log-wash-log 'cherry)
    "cherry" "-v" "--abbrev" args))

;;; Reflog Mode

(defvar magit-reflog-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-log-mode-map)
    map)
  "Keymap for `magit-reflog-mode'.")

(define-derived-mode magit-reflog-mode magit-log-mode "Magit Reflog"
  "Mode for looking at Git reflog.
This mode is documented in info node `(magit)Reflogs'.

\\<magit-reflog-mode-map>\
Type \\[magit-refresh] to refresh the current buffer.
Type \\[magit-show-commit] or \\[magit-show-or-scroll-up]\
 to visit the commit at point.
Type \\[magit-cherry-pick] to cherry-pick the commit at point.
Type \\[magit-reset-head] to reset HEAD to the commit at point.
\n\\{magit-reflog-mode-map}"
  :group 'magit-log)

(defun magit-refresh-reflog-buffer (ref)
  (magit-insert-section (reflogbuf)
    (magit-insert-heading "Local history of branch " ref)
    (magit-git-wash (apply-partially 'magit-log-wash-log 'reflog)
      "reflog" "show" "--format=format:%h [%an] %ct %gd %gs"
      (format "--max-count=%d" magit-log-cutoff-length) ref)))

(defvar magit-reflog-labels
  '(("commit"      . magit-reflog-commit)
    ("amend"       . magit-reflog-amend)
    ("merge"       . magit-reflog-merge)
    ("checkout"    . magit-reflog-checkout)
    ("branch"      . magit-reflog-checkout)
    ("reset"       . magit-reflog-reset)
    ("rebase"      . magit-reflog-rebase)
    ("cherry-pick" . magit-reflog-cherry-pick)
    ("initial"     . magit-reflog-commit)
    ("pull"        . magit-reflog-remote)
    ("clone"       . magit-reflog-remote)))

(defun magit-log-format-reflog (subject)
  (let* ((match (string-match magit-reflog-subject-re subject))
         (command (and match (match-string 1 subject)))
         (option  (and match (match-string 2 subject)))
         (type    (and match (match-string 3 subject)))
         (label (if (string= command "commit")
                    (or type command)
                  command))
         (text (if (string= command "commit")
                   label
                 (mapconcat #'identity
                            (delq nil (list command option type))
                            " "))))
    (format "%-16s "
            (propertize text 'face
                        (or (cdr (assoc label magit-reflog-labels))
                            'magit-reflog-other)))))

;;; Log Sections

(defvar magit-unpulled-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\r" 'magit-diff-unpulled)
    map)
  "Keymap for the `unpulled' section.")

(defun magit-insert-unpulled-commits ()
  (-when-let (tracked (magit-get-tracked-branch nil t))
    (magit-insert-section (unpulled)
      (magit-insert-heading "Unpulled commits:")
      (magit-insert-log (concat "HEAD.." tracked) magit-log-section-args))))

(defun magit-insert-unpulled-or-recent-commits ()
  (let ((tracked (magit-get-tracked-branch nil t)))
    (if (and tracked (not (equal (magit-rev-parse "HEAD")
                                 (magit-rev-parse tracked))))
        (magit-insert-unpulled-commits)
      (magit-insert-recent-commits))))

(defun magit-insert-recent-commits ()
  (magit-insert-section (recent)
    (magit-insert-heading "Recent commits:")
    (magit-insert-log nil (cons (format "-%d" magit-log-section-commit-count)
                                magit-log-section-args))))

(defun magit-insert-unpulled-cherries ()
  (-when-let (tracked (magit-get-tracked-branch nil t))
    (magit-insert-section (unpulled)
      (magit-insert-heading "Unpulled commits:")
      (magit-git-wash (apply-partially 'magit-log-wash-log 'cherry)
        "cherry" "-v" (magit-abbrev-arg) (magit-get-current-branch) tracked))))

(defvar magit-unpushed-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\r" 'magit-diff-unpushed)
    map)
  "Keymap for the `unpushed' section.")

(defun magit-insert-unpushed-commits ()
  (-when-let (tracked (magit-get-tracked-branch nil t))
    (magit-insert-section (unpushed)
      (magit-insert-heading "Unpushed commits:")
      (magit-insert-log (concat tracked "..HEAD") magit-log-section-args))))

(defun magit-insert-unpushed-cherries ()
  (-when-let (tracked (magit-get-tracked-branch nil t))
    (magit-insert-section (unpushed)
      (magit-insert-heading "Unpushed commits:")
      (magit-git-wash (apply-partially 'magit-log-wash-log 'cherry)
        "cherry" "-v" (magit-abbrev-arg) tracked))))

;;; Buffer Margins

(defun magit-set-buffer-margin (enable)
  (make-local-variable 'magit-log-show-margin)
  (let ((width (and enable
                    (if (and (derived-mode-p 'magit-log-mode)
                             (eq (car magit-refresh-args) 'long))
                        0 ; temporarily hide redundant margin
                      (car magit-log-margin-spec)))))
    (setq magit-log-show-margin width)
    (-when-let (window (get-buffer-window))
      (with-selected-window window
        (set-window-margins nil (car (window-margins)) width)
        (if enable
            (add-hook  'window-configuration-change-hook
                       'magit-set-buffer-margin-1 nil t)
          (remove-hook 'window-configuration-change-hook
                       'magit-set-buffer-margin-1 t))))))

(defun magit-set-buffer-margin-1 ()
  (-when-let (window (get-buffer-window))
    (with-selected-window window
      (set-window-margins nil (car (window-margins)) magit-log-show-margin))))

(defun magit-make-margin-overlay (&rest strings)
  (let ((o (make-overlay (point) (line-end-position) nil t)))
    (overlay-put o 'evaporate t)
    (overlay-put o 'before-string
                 (propertize "o" 'display
                             (list '(margin right-margin)
                                   (apply #'concat strings))))))

;;; magit-log.el ends soon
(provide 'magit-log)
;; Local Variables:
;; coding: utf-8
;; indent-tabs-mode: nil
;; End:
;;; magit-log.el ends here
