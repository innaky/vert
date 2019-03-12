(in-package :recurse.vert)

@export-class
(defclass object-manager (game-object)
  ()
  (:documentation "A game object which manages other game objects."))

@export
(defgeneric get-managed-objects (object-manager)
  (:method ((object-manager object-manager)) '()))
