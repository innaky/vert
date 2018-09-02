;; Implement audio-player with sdl2-mixer
(in-package :recurse.vert)

(defparameter *sfx-channel* 0 "SDL-Mixer Sound effect channel.")

(defparameter *sdl-mix-sample-size* 0 "Number of 8 bit ints in a sample.
Computed as (* (/ bit-rate 8) num-channels)")
(defparameter *sdl-mix-rate* 0 "Frequency sdl is mixing.")

(defclass sdl-audio-player (audio-player)
  ((chunk-cache :initform
                (let ((cache (make-instance 'evict-oldest-cache :test #'equalp
                                            :max-size 10
                                            :on-evict (lambda (path-to-file chunk)
                                                        (declare (ignore path-to-file))
                                                        ;; TODO this will be really bad
                                                        ;; if a channel is playing this wav
                                                        (sdl2-mixer:free-chunk chunk)))))
                  (when *memory-manager*
                    (register-cache *memory-manager* "sdl-chunk-cache" cache))
                  cache)
                :reader chunk-cache
                :allocation :class
                :documentation "Cache file-path->sdl-chunk")
   (music-cache :initform
                (let ((cache (make-instance 'evict-oldest-cache :test #'equalp
                                            :max-size 5
                                            :on-evict (lambda (path-to-file music)
                                                        (declare (ignore path-to-file))
                                                        ;; TODO this will be really bad
                                                        ;; if music is playing
                                                        (sdl2-mixer:free-music music)))))
                  (when *memory-manager*
                    (register-cache *memory-manager* "sdl-music-cache" cache))
                  cache)

                :reader music-cache
                :allocation :class
                :documentation "Cache file-path->sdl-music"))
  (:documentation "Music player implementation using sdl-mixer."))

(defun %query-sdl-spec ()
  (plus-c:c-with ((freq :int)
                  (fmt sdl2-ffi:uint16)
                  (chans :int))
    (sdl2-ffi.functions:mix-query-spec (freq plus-c:&) (fmt plus-c:&) (chans plus-c:&))
    (values freq fmt chans)))

(defun %get-music (audio-player path-to-music-file)
  (with-accessors ((cache music-cache)) audio-player
    (let ((value (getcache path-to-music-file cache)))
      (unless value
        (setf value (sdl2-mixer:load-music path-to-music-file))
        (setf (getcache path-to-music-file cache) value))
      value)))

(defun %get-sound-effect (audio-player path-to-music-file)
  (with-accessors ((cache chunk-cache)) audio-player
    (let ((value (getcache path-to-music-file cache)))
      (unless value
        (setf value (sdl2-mixer:load-wav path-to-music-file))
        (setf (getcache path-to-music-file cache) value))
      value)))


(eval-when (:compile-toplevel)
  (cffi:defcallback
      music-finished-callback :void ()
    "When music finishes playing queue up"
    (when *audio-player*
      ;; FIXME: should lock around setting audio player state
      (with-slots (num-music-plays) *audio-player*
        (case (music-state *audio-player*)
          (:playing
           (decf num-music-plays)
           (cond
             ((> num-music-plays 0) (setf (music-state *audio-player*) :playing))
             ((= num-music-plays 0) (setf (music-state *audio-player*) :stopped))
             (T (setf num-music-plays -1 (music-state *audio-player*) :playing))))
          (:stopped (setf num-music-plays 0))))))
  (unwind-protect
       (progn
         ;; lock all audio devices
         (sdl2-ffi.functions:sdl-lock-audio-device 1)
         (sdl2-ffi.functions:mix-hook-music-finished
          (cffi:callback music-finished-callback)))
    ;; unlock all audio devices
    (sdl2-ffi.functions:sdl-unlock-audio-device 1)))

;; audio player api implementation

(defmethod start-audio-player ((audio-player sdl-audio-player))
  (sdl2-mixer:init)
  (sdl2-mixer:open-audio +output-frequency-hz+ :s16sys 2 2048)
  (sdl2-mixer:allocate-channels 1)
  (sdl2-mixer:volume-music 128)
  (sdl2-mixer:volume *sfx-channel* 64)

  (multiple-value-bind (frequency format channels)
      (%query-sdl-spec)
    (let ((bits (logand format #XFF)))
      (unless (= bits +output-bit-depth+)
        (error "unsupported audio bit-depth: ~A" bits))
      (unless (= channels +output-num-channels+)
        (error "unsupported number of audio channels: ~A" channels))
      (unless (= +output-frequency-hz+ frequency)
        (error "unsupported frequency: ~A" frequency))
      (setf *sdl-mix-sample-size* (* (/ bits 8) channels))
      (setf *sdl-mix-rate* frequency)))
  (values))

(defmethod stop-audio-player ((audio-player sdl-audio-player))
  (sdl2-mixer:halt-music)
  (sdl2-mixer:halt-channel -1)
  (clear-cache (chunk-cache audio-player))
  (clear-cache (music-cache audio-player))
  (sdl2-mixer:close-audio)
  (sdl2-mixer:quit)
  (values))

(defmethod play-sound-effect ((audio-player sdl-audio-player) path-to-sfx-file &key rate)
  (declare (ignore rate))
  (sdl2-mixer:play-channel
   *sfx-channel*
   (%get-sound-effect audio-player path-to-sfx-file)
   ;; hardcoding a one-time play
   0))


(defmethod play-music ((audio-player sdl-audio-player) path-to-music-file &key (num-plays 1))
  (with-slots (num-music-plays
               current-music)
      audio-player
    (setf (music-state audio-player) :stopped
          num-music-plays num-plays
          current-music path-to-music-file
          (music-state audio-player) :playing)))

(defmethod (setf music-state) :after (value (audio-player sdl-audio-player))
  (with-slots (music-count music-queue)
      audio-player
    (ecase (music-state audio-player)
      (:playing
       (if (= 1 (sdl2-ffi.functions:mix-playing-music))
           (sdl2-ffi.functions:mix-resume-music)
           (unless (= 0 (sdl2-mixer:play-music
                         (%get-music audio-player (current-music audio-player)) 1))
             (error "sdl-mixer unable to play music: ~A"
                    (sdl2-ffi.functions:sdl-get-error)))))
      (:paused (sdl2-ffi.functions:mix-pause-music))
      (:stopped
       (sdl2-mixer:halt-music)))))
