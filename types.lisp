(in-package :serapeum)

(deftype wholenum ()
  "A whole number. Equivalent to `(integer 0 *)'."
  '(integer 0 *))

(deftype tuple (&rest types)
  "A proper list where each element has the same type as the corresponding element in TYPES.

    (typep '(1 :x #\c) '(tuple integer keyword character)) => T

As a shortcut, a quoted form among TYPES is expanded to an `eql' type specifier.
    (tuple 'function symbol)
    ≡ (tuple (eql function) symbol)

The same shortcut works for keywords.
    (tuple :name symbol)
    ≡ (tuple (eql :name) symbol)"
  (reduce (lambda (x y)
            (match x
              ((or (list 'quote form)
                   (and form (type keyword)))
               (setf x `(eql ,form))))
            `(cons ,x ,y))
          types
          :from-end t
          :initial-value 'null))

(deftype ok-hash-table-test ()
  '(and (or symbol function)
    (satisfies hash-table-test-p)))

(deftype -> (args values)
  "The type of a function from ARGS to VALUES."
  `(function ,args ,values))

(defun hash-table-test-p (x)
  (etypecase x
    (symbol (member x '(eq eql equal equalp)))
    (function (member x (load-time-value
                         (list #'eq #'eql #'equal #'equalp))))))

(defmacro -> (function args values)
  "Declaim the ftype of FUNCTION from ARGS to VALUES.

     (-> mod-fixnum+ (fixnum fixnum) fixnum)
     (defun mod-fixnum+ (x y) ...)"
  `(declaim (ftype (-> ,args ,values) ,function)))

(defmacro declaim-freeze-type (type)
  "Declare that TYPE is not going to change, for the benefit of Lisps
  that understand such declarations."
  (declare (ignorable type))
  #+sbcl  `(declaim (sb-ext:freeze-type ,type))
  #+cmucl `(declaim (ext:freeze-type ,type)))

(defmacro declaim-constant-function (&rest fns)
  "Declare that FNs are constant functions, for the benefit of Lisps
that understand such declarations."
  (declare (ignorable fns))
  #+cmucl
  `(progn
     ,@(loop for fn in fns
             collect `(declaim (ext:constant-function ,fn)))))

(defmacro truly-the (type &body (expr))
  #+sbcl `(sb-ext:truly-the ,type ,expr)
  #+cmucl `(ext:truly-the ,type ,expr)
  #-(or sbcl cmucl) `(the ,type ,expr))

(declaim (notinline %require-type %require-type-for))

(defun read-new-value ()
  "Read and evaluate a value."
  (format *query-io* "~&New value: ")
  (list (eval (read *query-io*))))

(defmacro wrong-type (datum type restart &body (report))
  `(restart-case
       (error 'type-error
              :datum ,datum
              :expected-type ,type)
     (,restart (new)
       :report ,report
       :interactive read-new-value
       new)))

(defun require-type (datum spec)
  (declare (optimize (debug 0)))
  (if (typep datum spec)
      datum
      (%require-type datum spec)))

(define-compiler-macro require-type (&whole call datum spec)
  (if (constantp spec)
      (let ((type (eval spec)))
        (once-only (datum)
          `(if (typep ,datum ,spec)
               ,datum
               (truly-the ,type
                 (%require-type ,datum ,spec)))))
      call))

(defun %require-type (datum spec)
  (declare (optimize (debug 0)))
  (let ((new (wrong-type datum spec use-value
               "Supply a value to use instead")))
    (require-type new spec)))

(defun require-type-for (datum spec place)
  (declare (optimize (debug 0)))
  (if (typep datum spec)
      datum
      (%require-type-for datum spec place)))

(define-compiler-macro require-type-for (&whole call datum spec place)
  (if (constantp spec)
      (let ((type (eval spec)))
        (once-only (datum)
          `(if (typep ,datum ,spec)
               ,datum
               (truly-the ,type
                 (%require-type-for ,datum ,spec ,place)))))
      call))

(defun %require-type-for (datum spec place)
  (declare (optimize (debug 0)))
  (let ((new (wrong-type datum spec store-value
               (lambda (s) (format s "Supply a new value for ~s" place)))))
    (require-type-for new spec place)))

(defmacro assure (type-spec &body (form) &environment env)
  "Macro for inline type checking.

`assure' is to `the' as `check-type' is to `declare'.

     (the string 1)    => undefined
     (assure string 1) => error

The value returned from the `assure' form is guaranteed to satisfy
TYPE-SPEC. If FORM does not return a value of that type, then a
correctable error is signaled. You can supply a value of the correct
type with the `use-value' restart.

Note that the supplied value is *not* saved into the place designated
by FORM. (But see `assuref'.)

From ISLISP."
  ;; The type nil contains nothing, so it renders the form
  ;; meaningless.
  (assert (not (subtypep type-spec nil)))
  (let ((exp (macroexpand form env)))
    ;; A constant expression.
    (when (constantp exp)
      (let ((val (constant-form-value exp)))
        (unless (typep val type-spec)
          (warn "Constant expression ~s is not of type ~a"
                form type-spec))))
    ;; A variable.
    (when (symbolp exp)
      (let ((declared-type (variable-type exp env)))
        (unless (subtypep type-spec declared-type)
          (warn "Required type ~a is not a subtypep of declared type ~a"
                type-spec declared-type)))))

  ;; `values' is hand-holding for SBCL.
  `(the ,type-spec (values (require-type ,form ',type-spec))))

(defmacro assuref (place type-spec)
  "Like `(progn (check-type PLACE TYPE-SPEC) PLACE)`, but evaluates
PLACE only once."
  (with-gensyms (temp)
    (let ((ts type-spec))
      `(the ,ts
            (values
             (let ((,temp ,place))
               (if (typep ,temp ',ts)
                   ,temp
                   (setf ,place (require-type-for ,temp ',ts ',place)))))))))

;;; These are helpful for development.
(progn
  (defmacro variable-type-in-env (&environment env var)
    `(values ',(variable-type var env)
             ;; So it's not unused.
             ,var))

  (defmacro policy-quality-in-env (&environment env qual)
    `',(policy-quality qual env)))

(defun simplify-subtypes (subtypes)
  (let* ((unique (remove-duplicated-subtypes subtypes))
         (sorted (sort-subtypes unique))
         (unshadowed (remove-shadowed-subtypes sorted)))
    unshadowed))

(defun remove-duplicated-subtypes (subtypes)
  (remove-duplicates subtypes :test #'type=))

(defun proper-subtypep (subtype type)
  (and (subtypep subtype type)
       (not (subtypep type subtype))))

(defun sort-subtypes (subtypes)
  (let ((sorted (stable-sort subtypes #'proper-subtypep)))
    (prog1 sorted
      ;; Subtypes must always precede supertypes.
      (assert
       (loop for (type1 . rest) on sorted
             never (loop for type2 in rest
                           thereis (proper-subtypep type2 type1)))))))

(defun remove-shadowed-subtypes (subtypes)
  (assert (equal subtypes (sort-subtypes subtypes)))
  (labels ((rec (subtypes supertypes)
             (if (null subtypes)
                 (nreverse supertypes)
                 (let ((type (first subtypes))
                       (supertype (cons 'or supertypes)))
                   (if (type= type supertype)
                       ;; Type is shadowed, ignore it.
                       (rec (cdr subtypes) supertypes)
                       (rec (cdr subtypes)
                            (cons type supertypes)))))))
    (rec subtypes nil)))

(defun subtypes-exhaustive? (type subtypes &optional env)
  (loop for subtype in subtypes
        unless (subtypep subtype type env)
          do (error "~s is not a subtype of ~s" subtype type))
  (type= type `(or ,@subtypes)))

(defparameter *vref-by-type*
  (stable-sort
   '((simple-bit-vector . sbit)
     (bit-vector . bit)
     (string . char)
     (simple-string . schar)
     (simple-vector . svref)
     (t . aref))
   #'proper-subtypep
   :key #'car))

(defun type-vref (type)
  (let ((sym (cdr (assoc type *vref-by-type* :test #'subtypep))))
    (assert (and (symbolp sym) (not (null sym))))
    sym))

(defmacro vref (vec index &environment env)
  "When used globally, same as `aref'.

Inside of a with-type-dispatch form, calls to `vref' may be bound to
different accessors, such as `char' or `schar', or `bit' or `sbit',
depending on the type being specialized on."
  (if (symbolp vec)
      (let* ((type (variable-type vec env))
             (vref (type-vref type)))
        `(,vref ,vec ,index))
      `(aref ,vec ,index)))

(defmacro with-vref (type &body body)
  ;; Although this macro is only intended for internal use, package
  ;; lock violations can still occur when functions it is used in are
  ;; inlined.
  (let ((vref (type-vref type)))
    (if (eql vref 'aref)
        `(progn ,@body)
        `(locally (declare #+sbcl (sb-ext:disable-package-locks vref))
           (macrolet ((vref (v i) (list ',vref v i)))
             (declare #+sbcl (sb-ext:enable-package-locks vref))
             ,@body)))))

(defmacro with-type-dispatch (&environment env (&rest types) var &body body)
  "A macro for writing fast sequence functions (among other things).

In the simplest case, this macro produces one copy of BODY for each
type in TYPES, with the appropriate declarations to induce your Lisp
to optimize that version of BODY for the appropriate type.

Say VAR is a string. With this macro, you can trivially emit optimized
code for the different kinds of string that VAR might be. And
then (ideally) instead of getting code that dispatches on the type of
VAR every time you call `aref', you get code that dispatches on the
type of VAR once, and then uses the appropriately specialized
accessors. (But see `with-string-dispatch'.)

But that's the simplest case. Using `with-type-dispatch' also provides
*transparent portability*. It examines TYPES to deduplicate types that
are not distinct on the current Lisp, or that are shadowed by other
provided types. And the expansion strategy may differ from Lisp to
Lisp: ideally, you should not have to pay for good performance on
Lisps with type inference with pointless code bloat on other Lisps.

There is an additional benefit for vector types. Around each version
of BODY, the definition of `vref' is shadowed to expand into an
appropriate accessor. E.g., within a version of BODY where VAR is
known to be a `simple-string', `vref' expands into `schar'.

Using `vref' instead of `aref' is obviously useful on Lisps that do
not do type inference, but even on Lisps with type inference it can
speed compilation times (compiling `aref' is relatively slow on SBCL).

Within `with-type-dispatch', VAR should be regarded as read-only.

Note that `with-type-dispatch' is intended to be used around
relatively expensive code, particularly loops. For simpler code, the
gains from specialized compilation may not justify the overhead of the
initial dispatch and the increased code size.

Note also that `with-type-dispatch' is relatively low level. You may
want to use one of the other macros in the same family, such as
`with-subtype-dispatch', `with-string-dispatch', or so forth.

The design and implementation of `with-type-dispatch' is based on a
few sources. It replaces a similar macro formerly included in
Serapeum, `with-templated-body'. One possible expansion is based on
the `string-dispatch' macro used internally in SBCL. But most of the
credit should go to the paper \"Fast, Maintable, and Portable Sequence
Functions\", by Irène Durand and Robert Strandh."
  (let ((types (simplify-subtypes types)))
    (cond ((null types)
           `(progn ,@body))
          ;; The advantage of the CMUCL/SBCL way (I hope) is that the
          ;; compiler can decide /not/ to bother inlining if the type
          ;; is such that it cannot do any meaningful optimization.
          ((or #+(or cmucl sbcl) t)
           ;; Cf. sb-impl::string-dispatch.
           (with-unique-names ((fun type-dispatch-fun))
             `(flet ((,fun (,var)
                       (with-read-only-var (,var)
                         ,@body)))
                (declare (inline ,fun))
                (etypecase ,var
                  ,@(loop for type in types
                          collect `(,type (,fun (truly-the ,type ,var))))))))
          ;; Try to force CCL to trust our declarations. According to
          ;; <https://trac.clozure.com/ccl/wiki/DeclareOptimize>, that
          ;; requires safety<3 and speed>=safety. But, if the
          ;; pre-existing values for safety and speed are acceptable,
          ;; we don't want to overwrite them.
          ((or #+ccl t)
           (multiple-value-bind (speed safety)
               (let ((speed  (policy-quality 'speed env))
                     (safety (policy-quality 'safety env)))
                 (if (and (< safety 3)
                          (>= speed safety))
                     (values speed safety)
                     (let* ((safety (min safety 2))
                            (speed  (max speed safety)))
                       (values speed safety))))
             (assert (and (< safety 3)
                          (>= speed safety)))
             `(locally
                  (declare
                   (optimize (speed ,speed)
                             (safety ,safety)))
                (etypecase ,var
                  ,@(loop for type in types
                          collect `(,type
                                    (locally (declare (type ,type ,var))
                                      (with-read-only-var (,var)
                                        ,@body))))))))
          ;; If you know how to make this work more efficiently on a
          ;; particular Lisp implementation, feel free to make a pull
          ;; request, or open an issue.
          (t
           `(etypecase ,var
              ,@(loop for type in types
                      collect `(,type
                                ;; Overkill?
                                (locally (declare (type ,type ,var))
                                  (let ((,var ,var))
                                    (declare (type ,type ,var))
                                    (with-read-only-var (,var)
                                      ,@body))))))))))

(defmacro with-subtype-dispatch (type (&rest subtypes) var &body body
                                 &environment env)
  "Like `with-type-dispatch', but SUBTYPES must be subtypes of TYPE.

Furthermore, if SUBTYPES are not exhaustive, an extra clause will be
added to ensure that TYPE itself is handled."
  (let* ((types
           (if (subtypes-exhaustive? type subtypes env)
               subtypes
               (append subtypes (list type)))))
    `(with-type-dispatch ,types ,var
       ,@body)))

(defmacro with-string-dispatch ((&rest types) var &body body)
  "Like `with-subtype-dispatch' with an overall type of `string'."
  `(with-subtype-dispatch string
       ;; Always specialize for (simple-array character (*)).
       ((simple-array character (*))
        (simple-array base-char (*))
        ,@types)
       ,var
     ,@body))

(defmacro with-vector-dispatch ((&rest types) var &body body)
  "Like `with-subtype-dispatch' with an overall type of `vector'."
  ;; Always specialize for simple vectors.
  `(with-subtype-dispatch vector (simple-vector ,@types) ,var
     ,@body))

;;; Are these worth exporting?

(defmacro with-boolean (var &body body)
  `(with-read-only-var (,var)
     (if ,var
         ,@body
         ,@body)))

(defmacro with-nullable ((var type) &body body)
  `(with-type-dispatch (null ,type) ,var
     ,@body))
