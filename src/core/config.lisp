(in-package :recurse.vert)

@export-class
(defclass config ()
  ((%config-hash :initform (make-hash-table)))
  (:documentation "Immutable. Conceptually a map of keys (symbol) to values (T)"))

@export
(defun getconfig (key config)
  (declare (symbol key)
           (config config))
  (gethash key (slot-value config '%config-hash)))

@export
(defmacro make-config ((&optional base-config) &rest key-value-pairs)
  "Create a config out of KEY-VALUE-PAIRS. If supplied all values from BASE-CONFIG will be copied over.

Each pair is a two value list with the first value being a symbol. Any keys present in BASE-CONFIG will be overridden by these values.

Example:
  (make-config (*default-config*) ('foo \"foo val\") ('bar \"bar val\"))"
  (when base-config (error "base-config not implemented yet"))
  (alexandria:with-gensyms (config hash)
    `(let ((,config (make-instance 'config)))
       (with-slots ((,hash %config-hash)) ,config
         ,@(loop :with config-setters = (list)
              :for key-val :in key-value-pairs :do

                (unless (and (listp key-val) (= 2 (length key-val)))
                  (error "key-value-pairs must be two arg list of (key val). Got ~A" key-val))
                (push `(setf (gethash (runtime-type-assert
                                       ,(first key-val)
                                       'symbol
                                       "config keys must be symbols")
                                      ,hash)
                             ,(second key-val))
                      config-setters)
              :finally (return (nreverse config-setters)))
         ,config))))

@export
(defun export-config-key (symbol &optional documentation)
  (export (list symbol))
  (when documentation
    (setf (documentation symbol 'variable) documentation)))

(export-config-key
 'config-resource-dirs "Dirs to check when looking for a resource. See RESOURCE-PATH.")
(export-config-key
 'game-name "Name of the game. Will affect the executable name and window title.")
(export-config-key
 'window-icon "Path to a PNG to use for the window icon. Path must be a relative path to the active config's RESOURCE-PATH. May be nil.")

@export
(defvar *default-config* (make-config ()
                                      ('config-resource-dirs (list "./resources"))
                                      ('game-name "VertGame")
                                      ('window-icon nil))
  "The config used by vert if no config is specified.")

@export
(defvar *config*
  nil
  "The active config")
