(in-package :recurse.vert)

@export
(defvar *engine-manager*
  nil
  "State used to run the game loop")

@export
(defvar *scene*
  nil
  "The active scene being updated")

(declaim ((integer 1 100) *timestep*))
@export
(defvar *timestep*
  24
  "Duration of the update timeslice in milliseconds.")

(defclass engine-manager (event-publisher)
  ;; global services
  ((initial-scene-creator-fn :initform nil
                             :reader initial-scene-creator-fn
                             :documentation "A zero-arg function which returns the first scene to use for engine.")
   (input-manager :initform (make-instance 'input-manager)
                  :reader input-manager)
   (application-window :initarg :application-window
                       :initform nil
                       :reader application-window
                       :documentation "Underlying application window.")
   (rendering-context :initarg :rendering-context
                      :initform nil
                      :reader rendering-context
                      :documentation "Rendering context of the application window.")
   (audio-player :initarg :audio-player
                 :initform nil
                 :reader audio-player
                 :documentation "System audio player.")
   (pending-scene-changes :initform nil)
   (pending-action :initform 'no-action
                   :documentation "A zero-arg lambda to execute at the end of the next game loop iteration")
   (clear-color :initform *black*
                :accessor clear-color
                :documentation "Set the clear color for the rendering window.")
   (lag-ns :initform 0
           :accessor lag-ns)
   (last-loop-start-ns :initform (ticks-nanos) :accessor last-loop-start-ns)
   (game-stats :initform (make-array 1
                                     :element-type 'game-stats
                                     :initial-element (make-instance 'builtin-vert-stats)
                                     :fill-pointer 1
                                     :adjustable t)
               :reader game-stats)
   (screen-camera :initform nil)
   (stats-hud :initform nil :accessor stats-hud))
  (:documentation "Starts and stops the game. Manages global engine state and services."))
(export '(rendering-context))

(defmethod initialize-instance :after ((engine-manager engine-manager) &rest args)
  (declare (ignore args))
  (with-slots (game-stats stats-hud) engine-manager
    (setf stats-hud (make-instance 'stats-hud
                                   :game-stats game-stats
                                   :width (first (getconfig 'game-resolution *config*))
                                   :height (second (getconfig 'game-resolution *config*))))))

(defgeneric quit-engine (engine-manager)
  (:documentation "Stop the running game engine"))

(defgeneric render-game-window (engine-manager)
  (:documentation "Render the current rendering context to the application-window."))

(defgeneric run-game-loop (engine-manager)
  (:documentation "Provided by engine-manager subclasses. Runs the game loop."))

(defevent engine-started ((engine-manager engine-manager))
    "Fired once when the engine starts running.")
(defevent engine-stopped ((engine-manager engine-manager))
    "Fired once when the engine stops running.")

(defun active-scene (engine-manager)
  (declare (ignore engine-manager))
  *scene*)

@export
(defun garbage-collect-hint ()
  "Hint to Vert that a costly GC may be run."
  (sb-ext:gc :full t)
  (resource-autoloader-prune-empty-refs *resource-autoloader*)
  (run-all-free-releasers))

@export
(defun change-scene (engine-manager new-scene &optional (release-existing-scene T) (run-full-gc nil) (preserve-audio nil))
  "At the beginning of the next game loop, Replace the active-scene with NEW-SCENE.
If RELEASE-EXISTING-SCENE is non-nil (the default), the current active-scene will be released."
  (let ((old-scene *scene*))
    (unless (eq old-scene new-scene)
      (when (slot-value engine-manager 'pending-scene-changes)
        (error "Scene change already pending"))
      (setf (slot-value engine-manager 'pending-scene-changes)
            (lambda ()
              (when (and old-scene (current-music *audio*))
                ;; Hack to resume music on unpause
                (unless preserve-audio
                  (if release-existing-scene
                      (setf (music-state *audio*) :stopped)
                      (setf (music-state *audio*) :paused))))
              #+nil
              (when (and old-scene release-existing-scene)
                (garbage-collect-hint))
              (when new-scene
                (when (typep new-scene 'game-scene)
                  ;; Hack to resume game-scene music on unpause
                  (with-accessors ((music scene-music)) new-scene
                    (when music
                      (if (eq :paused (music-state *audio*))
                          (setf (music-state *audio*) :playing)
                          (play-music *audio* music :num-plays -1)))))
                (do-input-devices device (input-manager engine-manager)
                  (add-scene-input new-scene device)))
              (setf *scene* new-scene)
              (multiple-value-bind (width-px height-px)
                  (window-size-pixels (application-window *engine-manager*))
                (after-resize-window (application-window engine-manager) width-px height-px))
              (when (and preserve-audio
                         (typep old-scene 'pause-scene)
                         (eq :paused (music-state *audio*)))
                (setf (music-state *audio*) :playing))
              (block run-gc
                (setf old-scene nil)
                (when run-full-gc
                  (garbage-collect-hint)))))))
  (values))

(defgeneric game-loop-iteration (engine-manager)
  (:documentation "Run a single iteration of the game loop.")
  (:method ((engine-manager engine-manager))
    (declare (optimize (speed 3)))
    ;; first run any pending scene changes
    (with-slots (pending-scene-changes) engine-manager
      (when pending-scene-changes
        (let ((pending pending-scene-changes))
          (declare (function pending))
          (setf pending-scene-changes nil)
          (funcall pending))))
    ;; then any pending dev actions
    ;; (with-slots (pending-action) engine-manager
    ;;   (unless (eq 'no-action pending-action)
    ;;     (let ((pending pending-action))
    ;;       (declare (function pending))
    ;;       (sb-ext:atomic-update pending-action
    ;;                             (lambda (previous-action)
    ;;                               (declare (ignore previous-action))
    ;;                               'no-action))
    ;;       (funcall pending))))
    (update-swank)
    ;; I've considered wrapping this methig in (sb-sys:without-gcing)
    ;; to prevent short GCs from dropping the FPS.
    ;; But it seems like that could deadlock if the game is multithreaded.
    (with-accessors ((active-scene active-scene)
                     (renderer rendering-context)
                     (lag lag-ns)
                     (game-stats game-stats)
                     (stats-hud stats-hud)
                     (last-loop-start last-loop-start-ns))
        engine-manager
      (declare (fixnum last-loop-start lag))
      (let* ((now-ns (ticks-nanos))
             (delta-ns (- (the fixnum now-ns) last-loop-start))
             (timestep-ns (* *timestep* #.(expt 10 6))))
        (declare (fixnum now-ns delta-ns timestep-ns))
        (setf last-loop-start now-ns)
        (incf lag delta-ns)

        (when (>= lag (* 10 timestep-ns))
          ;; update thread was likely just blocked on debugging. Don't try to catch up.
          (log:warn "Update thread very far behind. Resetting to a good state.~%")
          (setf lag timestep-ns))
        (loop :for i :from 0 :while (>= lag timestep-ns) :do
             (decf lag timestep-ns)
             (when (get-dev-config 'dev-mode-performance-hud)
               (loop :for stats :across game-stats :do
                    (when (typep stats 'builtin-vert-stats)
                      (pre-update-frame stats))))
             (update active-scene *timestep* nil)
             (when (get-dev-config 'dev-mode-performance-hud)
               (loop :for stats :across game-stats :do
                    (when (typep stats 'builtin-vert-stats)
                      (post-update-frame stats)))))
        (when (get-dev-config 'dev-mode-performance-hud)
          (loop :for stats :across game-stats :do
               (when (typep stats 'builtin-vert-stats)
                 (pre-render-frame stats))))
        (render active-scene
                (coerce (/ lag timestep-ns) 'single-float)
                nil
                renderer)
        (when (get-dev-config 'dev-mode-performance-hud)
          (render stats-hud 1.0 (slot-value engine-manager 'screen-camera) renderer))
        (when (get-dev-config 'dev-mode-performance-hud)
          (loop :for stats :across game-stats :do
               (when (typep stats 'builtin-vert-stats)
                 (post-render-frame stats))))
        (render-game-window engine-manager)))))

(defgeneric run-game (engine-manager initial-scene-creator)
  (:documentation "Initialize ENGINE-MANAGER and start the game.
The INITIAL-SCENE-CREATOR (zero-arg function) returns the first scene of the game.
It is invoked after the engine is fully started.")
  (:method ((engine-manager engine-manager) initial-scene-creator)
    (unwind-protect
         (progn
           (start-live-coding)
           (do-cache (*engine-caches* cache-name cache)
             (clear-cache cache))
           ;; start services
           (setf (slot-value engine-manager 'audio-player)
                 (start-audio-system))
           ;; fire events
           (fire-event engine-manager engine-started)
           ;; set up initial active-scene
           (setf (slot-value engine-manager 'initial-scene-creator-fn) initial-scene-creator)
           (log:info "Running ~A engine start hooks" (hash-table-size *engine-start-hooks*))
           (loop :for label :being :the hash-keys :of *engine-start-hooks*
              :using (hash-value hook)
              :do
                (log:info "-- start hook: ~A" label)
                (funcall hook))
           (with-slots (screen-camera) engine-manager
             (setf screen-camera
                   (make-instance 'camera
                                  :width (first (getconfig 'game-resolution *config*))
                                  :height (second (getconfig 'game-resolution *config*))))
             (update screen-camera *timestep* nil)
             (update screen-camera *timestep* nil))
           (change-scene engine-manager (funcall initial-scene-creator))
           (garbage-collect-hint)
           ;; run the game loop
           (run-game-loop engine-manager))
      (log:info "Game Complete. Cleaning up Engine.~%")
      (cleanup-engine engine-manager))))

(defgeneric cleanup-engine (engine-manager)
  (:documentation "Called once at engine shutdown. Clean up engine state.")
  (:method ((engine-manager engine-manager))
    (stop-live-coding)
    (change-scene engine-manager nil)
    (with-slots (pending-scene-changes) engine-manager
      (when pending-scene-changes
        (funcall pending-scene-changes)
        (setf pending-scene-changes nil)))
    (fire-event engine-manager engine-stopped)
    (log:info "Running ~A engine stop hooks" (hash-table-size *engine-stop-hooks*))
    (loop :for label :being :the hash-keys :of *engine-stop-hooks*
       :using (hash-value hook)
       :do
         (log:info "-- stop hook: ~A" label)
         (funcall hook))
    (log:info "running final GC")
    (garbage-collect-hint) ; run any resource finalizers
    (log:info "clearing all caches")
    (do-cache (*engine-caches* cache-name cache)
      (log:info " -- clearing ~A" cache-name)
      (clear-cache cache))
    (log:info "stopping global services")
    ;; stop services
    (stop-audio-system)
    (setf *gl-context* nil)
    (format t "~%~%")))

;;;; live coding
(declaim ((or null (function () *)) *live-coding-fn*))
(defvar *live-coding-fn*
  nil)

(defun start-live-coding ()
  "Enable live coding (if swank is present)"
  ;; read-from string so this file will compile without swank
  (setf *live-coding-fn*
        (eval
         (read-from-string
          "#+swank
           (lambda ()
             (declare (optimize (speed 3)))
             (let ((connection (or swank::*emacs-connection*
                                   (swank::default-connection))))
               (when connection
                 (swank::handle-requests connection t))
               (values)))")))
  (if *live-coding-fn*
      (log:info "Live coding started.")
      (log:info "Live coding unavailable.")))

(defun stop-live-coding ()
  "Disable live coding"
  (when *live-coding-fn*
    (setf *live-coding-fn* nil)
    (log:info "Live coding stopped.")))

(defun update-swank ()
  "Update swank events."
  (declare (optimize (speed 3)))
  (when *live-coding-fn*
    (locally (declare ((function () *) *live-coding-fn*))
      (funcall *live-coding-fn*)))
  nil)

;;;; on-game-thread macro

@export
(defmacro on-game-thread (&body body)
  "Run BODY on vert's game-thread at the end of the next loop iteration."
  `(if (on-game-thread-p)
       (progn ,@body)
       (unless (eq 'no-action
                   (sb-ext:compare-and-swap (slot-value *engine-manager* 'pending-action)
                                            'no-action
                                            (lambda () ,@body)))
         (error "Action already pending"))))
