(in-package :recurse.vert)

(defvar *vert-thread* nil)

@export
(defun on-game-thread-p ()
  (eq *vert-thread* (bt:current-thread)))

(defparameter *engine-manager*
  nil
  "Manages the current scene and runs the game loop")

(defun main (scene-creator-function &key (block T)
                                      (dev-mode nil)
                                      (audio-player (make-instance 'sdl-audio-player))
                                      (config *default-config*))
  "Start the game engine. No effect if the engine is already started."
  (declare (config config)
           ((or null config) dev-mode)
           (audio-player audio-player)
           (function scene-creator-function))
  (unless *engine-manager*
    #+os-macosx
    (unless (and (eq (or #+sbcl (sb-thread:main-thread)
                         (error "unable to find main thread for lisp impl ~A:~A"
                                (lisp-implementation-type)
                                (lisp-implementation-version)))
                     (current-thread))
                 block)
      (error "osx will crash if any thread other than thread0 issues drawing calls"))
    (setf *config* config
          *engine-manager* (make-instance 'sdl-engine-manager)
          *dev-mode* dev-mode
          *audio* audio-player)
    (labels ((run-engine ()
               (unwind-protect
                    (progn ; set log4cl to a base state
                      (log:config :sane)
                      (log:config :remove 1))
                    (when (getconfig 'log-output *config*)
                      (if (eq :stdout (getconfig 'log-output *config*))
                          (log:config :console)
                          (log:config :daily (getconfig 'log-output *config*) :backup nil)))
                    (assert-units)
                    (sdl2:make-this-thread-main
                     (lambda ()
                       (setf *vert-thread* (bt:current-thread))
                       (run-game *engine-manager* scene-creator-function)))
                 (setf *engine-manager* nil
                       *config* nil
                       *vert-thread* nil
                       *dev-mode* nil)
                 (garbage-collect-hint))))
      (if t ; TODO: remove block parameter entirely
          (run-engine)
          (make-thread #'run-engine :name "vert-game-loop")))))

(defun quit ()
  "Stop the running game engine."
  (when *engine-manager*
    (quit-engine *engine-manager*)))

(defun %reload-all-shaders ()
  ;; first clear out any existing gl errors
  (gl:get-error)
  (do-cache (*shader-cache* shader-key shader)
    (log:info "reload: ~A -- ~A~%" shader-key shader)
    (loop :with shader-loaded = nil
       :while (not shader-loaded) :do
         (restart-case
             ;; wrap in loop so we can retry shader load if there is an error
             (progn (release-resources shader)
                    (load-resources shader t)
                    (setf shader-loaded t))
           (retry-shader-load () :report "Retry loading shader"))))
  (gl-context-clear-all *gl-context*))

;; TODO: generalize resource reloading
@export
(defun reload-all-shaders ()
  (on-game-thread
    (%reload-all-shaders)))

@export
(defvar *vert-build-version* nil
  "version control id vert was built against.")

(eval-when (:compile-toplevel :load-toplevel)
  (defun git-id ()
    "Return a string describing the current git-tag or commit sha if not on a tag."
    (delete #\newline
            (with-output-to-string (cmd-stream)
              (or (uiop:run-program "git describe --exact-match --tags --abbrev=0"
                                    :ignore-error-status T
                                    :output cmd-stream)
                  (uiop:run-program "git rev-parse --short HEAD" :output cmd-stream)))))

  (let ((orig-dir (sb-posix:getcwd)))
    (unwind-protect
         (progn
           (sb-posix:chdir
            (asdf:system-source-directory :vert))
           (setf *vert-build-version* (git-id)))
      (sb-posix:chdir orig-dir))))
