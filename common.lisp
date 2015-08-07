(in-package #:snooze-common)


;;; Verbs
;;;
;;; "Sending" and "Receiving" are always from the server's
;;; perspective. Hence GET is "sending to client" and POST and PUT are
;;; "receiving from client".
;;; 
(defpackage :snooze-verbs (:use) (:export #:http-verb #:get #:post #:put #:delete
                                          #:content-verb
                                          #:receiving-verb
                                          #:sending-verb))

(cl:defclass snooze-verbs:http-verb      () ())
(cl:defclass snooze-verbs:delete         (snooze-verbs:http-verb) ())
(cl:defclass snooze-verbs:content-verb   (snooze-verbs:http-verb) ())
(cl:defclass snooze-verbs:receiving-verb (snooze-verbs:content-verb) ())
(cl:defclass snooze-verbs:sending-verb   (snooze-verbs:content-verb) ())
(cl:defclass snooze-verbs:post           (snooze-verbs:receiving-verb) ())
(cl:defclass snooze-verbs:put            (snooze-verbs:receiving-verb) ())
(cl:defclass snooze-verbs:get            (snooze-verbs:sending-verb) ())

(defun destructive-p (verb) (typep verb 'snooze-verbs:receiving-verb))


;;; Content-types
;;;
;;; For PUT and POST requests we match routes based on what the client
;;; declares to us in its "Content-Type" header. At most one CLOS
;;; primary method may match.
;;;
;;; In GET requests we are only interested in the request's "Accept"
;;; header, since GET never have useful bodies (1) and as such don't
;;; have "Content-Type". For GET requests, the logic is actually
;;; inverse: the routes are matched based on what the client accepts.
;;; If it accepts a range of content-types, multiple routes (or
;;; primary CLOS methods) are now eligible. We try many routes in
;;; order (according to that range) until we find one that matches.
;;;
;;; [1]: http://stackoverflow.com/questions/978061/http-get-with-request-body
;;;
(defclass snooze-types:content () ())

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun intern-safe (designator package)
    (intern (string-upcase designator) package))
  (defun scan-to-strings* (regex string)
    (coerce (nth-value 1
                       (cl-ppcre:scan-to-strings regex
                                                 string))
            'list)))

(defmacro define-content (type-designator
                          &optional (supertype-designator
                                     (first (scan-to-strings* "([^/]+)" type-designator))))
  (let* ((type (intern-safe type-designator :snooze-types))
         (supertype (intern-safe supertype-designator :snooze-types)))
    `(progn
       (setf (get ',type 'name) ,(string-downcase (symbol-name type)))
       (unless (find-class ',supertype nil)
         (setf (get ',supertype 'name) ,(format nil "~a/*"
                                               (string-downcase (symbol-name supertype))))
         (defclass ,supertype (snooze-types:content) ()))
       (defclass ,type (,supertype) ())
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (export '(,type ,supertype) :snooze-types)))))

(defmacro define-known-content-types ()
  `(progn
     ,@(loop for (type-spec . nil) in *mime-type-list*
             for matches = (nth-value 1 (cl-ppcre:scan-to-strings "(.*/.*)(?:;.*)?" type-spec))
             for type = (and matches (aref matches 0))
             when type
               collect `(define-content ,type))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (define-known-content-types))

(defun find-content-class (designator)
  "Return class for DESIGNATOR if it defines a content-type or nil."
  (cond ((typep designator 'snooze-types:content)
         (class-of designator))
        ((and (typep designator 'class)
              (subtypep designator 'snooze-types:content))
         designator)
        ((eq designator t)
         (alexandria:simple-style-warning
                     "Coercing content-designating type designator T to ~s"
                     'snooze-types:content)
         (find-class 'snooze-types:content))
        ((or (symbolp designator)
             (stringp designator))
         (or (find-class (intern (string-upcase designator) :snooze-types) nil)
             (and (string= designator "*/*") (find-class 'snooze-types:content))
             (let* ((matches (nth-value 1
                                        (cl-ppcre:scan-to-strings
                                         "([^/]+)/\\*"
                                         (string-upcase designator))))
                    (supertype-designator (and matches
                                               (aref matches 0))))
               (find-class
                (intern (string-upcase supertype-designator) :snooze-types)
                nil))))
        (t
         (error "~a cannot possibly designate a content-type" designator))))

(defun content-class-name (designator)
  (get (class-name (find-content-class designator)) 'name))



;;; Resources
;;;
(defun resource-p (thing)
  (and (functionp thing)
       (eq 'resource-generic-function (type-of thing))))

(deftype resource ()
  `(satisfies resource-p))

(defclass resource-generic-function (cl:standard-generic-function)
  ()
  (:metaclass closer-mop:funcallable-standard-class))

(defun resource-name (resource)
  (string (closer-mop:generic-function-name resource)))

(defvar *all-resources* nil)

(defun find-resource (designator &optional errorp)
  (cond ((or (stringp designator)
             (keywordp designator))
         (find designator *all-resources*
               :key #'resource-name :test #'string-equal))
        ((and (resource-p designator)
              (find designator *all-resources*))
         designator)
        ((and designator
              (symbolp designator)
              (fboundp designator)
              (resource-p (symbol-function designator))
              (find (symbol-function designator) *all-resources*))
         (symbol-function designator))
        (errorp
         (error "~a doesn't designate a known RESOURCE" designator))))

(defun delete-resource (resource)
  (setf *all-resources* (delete resource *all-resources*)))

(defmethod initialize-instance :after ((gf resource-generic-function) &rest args)
  (declare (ignore args))
  (pushnew gf *all-resources*))

(defun probe-class-sym (sym)
  "Like CL:FIND-CLASS but don't error and return SYM or nil"
  (when (find-class sym nil)
    sym))

(defun parse-defroute-args (defmethod-arglist)
  "Return values QUALIFIERS, LAMBDA-LIST, BODY for DEFMETHOD-ARGLIST"
  (loop for args on defmethod-arglist
        if (listp (first args))
          return (values qualifiers (first args) (cdr args))
        else
          collect (first args) into qualifiers))

(defun verb-spec-or-lose (verb-spec)
  "Convert VERB-SPEC into something CL:DEFMETHOD can grok."
  (labels ((verb-designator-to-verb (designator)
             (or (and (eq designator 't)
                      (progn
                        (alexandria:simple-style-warning
                         "Coercing verb-designating type T in ~a to ~s"
                              verb-spec 'snooze-verbs:http-verb)
                        'snooze-verbs:http-verb))
                 (probe-class-sym (intern (string-upcase designator)
                                          :snooze-verbs))
                 (error "Sorry, don't know the HTTP verb ~a"
                        (string-upcase designator)))))
    (cond ((and verb-spec
                (listp verb-spec))
           (list (first verb-spec) (verb-designator-to-verb (second verb-spec))))
          ((or (keywordp verb-spec)
               (stringp verb-spec))
           (list 'snooze-verbs:http-verb (verb-designator-to-verb verb-spec)))
          (verb-spec
           (list verb-spec 'snooze-verbs:http-verb))
          (t
           (error "~a is not a valid convertable HTTP verb spec" verb-spec)))))



(defun content-type-spec-or-lose-1 (type-spec)
  (labels ((type-designator-to-type (designator)
             (let ((class (find-content-class designator)))
               (if class (class-name class)
                   (error "Sorry, don't know the content-type ~a" type-spec)))))
    (cond ((and type-spec
                (listp type-spec))
           (list (first type-spec) (type-designator-to-type (second type-spec))))
          ((or (keywordp type-spec)
               (stringp type-spec))
           (list 'type (type-designator-to-type type-spec)))
          (type-spec
           (list type-spec (type-designator-to-type t))))))

(defun content-type-spec-or-lose (type-spec verb)
  (cond ((subtypep verb 'snooze-verbs:content-verb)
         (content-type-spec-or-lose-1 type-spec))
        ((and type-spec (listp type-spec))
         ;; specializations are not allowed on DELETE, for example
         (assert (eq t (second type-spec))
                 nil
                 "For verb ~a, no specializations on Content-Type are allowed"
                 verb)
         type-spec)
        (t
         (list type-spec t))))

(defun ensure-atom (thing)
  (if (listp thing)
      (ensure-atom (first thing))
      thing))

(defun ensure-uri (maybe-uri)
  (etypecase maybe-uri
    (string (quri:uri maybe-uri))
    (quri:uri maybe-uri)))

(defun parse-resource (uri)
  "Parse URI for a resource and how it should be called.

Honours of *RESOURCE-NAME-FUNCTION*, *RESOURCES-FUNCTION*,
*HOME-RESOURCE* and *URI-CONTENT-TYPES-FUNCTION*.

Returns nil if the resource cannot be found, otherwise returns 3
values: RESOURCE, URI-CONTENT-TYPES and RELATIVE-URI. RESOURCE is a
generic function verifying RESOURCE-P discovered in URI.
URI-CONTENT-TYPES is a list of subclasses of SNOOZE-TYPES:CONTENT
discovered in URI by *URI-CONTENT-TYPES-FUNCTION*. RELATIVE-URI is the
remaining URI after these discoveries."
  ;; <scheme name> : <hierarchical part> [ ? <query> ] [ # <fragment> ]
  ;;
  (let ((uri (ensure-uri uri))
        uri-stripped-of-content-type-info
        uri-content-types)
    (when *uri-content-types-function*
      (multiple-value-setq (uri-content-types uri-stripped-of-content-type-info)
        (funcall *uri-content-types-function* 
                                  (quri:render-uri uri nil))))
    (let* ((uri (ensure-uri (or uri-stripped-of-content-type-info
                                uri))))
      (multiple-value-bind (resource-name relative-uri)
          (funcall *resource-name-function*
                   (quri:render-uri uri))
        (setq resource-name (and resource-name
                                 (ignore-errors
                                  (quri:url-decode resource-name))))
        (let ((*all-resources* (funcall *resources-function*)))
          (values (find-resource (or resource-name
                                     *home-resource*))
                  (mapcar #'find-content-class uri-content-types)
                  relative-uri))))))

(defun content-classes-in-accept-string (string)
  (labels ((expand (class)
             (cons class
                   (reduce #'append (mapcar #'expand (closer-mop:class-direct-subclasses class))))))
    (loop for media-range-and-params in (cl-ppcre:split "\\s*,\\s*" string)
          for media-range = (first (scan-to-strings* "([^;]*)" media-range-and-params))
          for class = (find-content-class media-range)
          when class
            append (expand class))))

(defun arglist-compatible-p (resource args)
  (handler-case
      ;; FIXME: evaluate this need for eval, for security reasons
      (let ((*read-eval* nil))
        (handler-bind ((warning #'muffle-warning))
          (eval `(apply (lambda ,(closer-mop:generic-function-lambda-list
                                  resource)
                          t)
                        '(t t ,@args)))))
    (error () nil)))

(defun parse-content-type-header (string)
  "Return a symbol designating a SNOOZE-SEND-TYPE object."
  (find-content-class string))

(defun find-verb-or-lose (designator)
  (let ((class (or (probe-class-sym
                    (intern (string-upcase designator)
                            :snooze-verbs))
                   (error "Can't find HTTP verb for designator ~a!" designator))))
    ;; FIXME: perhaps use singletons here
    (make-instance class)))

(defun gf-primary-method-specializer (gf args ct-arg-pos)
  "Compute proper content-type for calling GF with ARGS"
  (let ((applicable (compute-applicable-methods gf args)))
    (when applicable
      (nth ct-arg-pos (closer-mop:method-specializers (first applicable))))))



;;; Internal symbols of :SNOOZE
;;;
(in-package :snooze)

(defun check-optional-args (opt-values &optional warn-p)
  (let ((nil-tail
          (member nil opt-values)))
  (unless (every #'null (rest nil-tail))
    (if warn-p
        (warn 'style-warning :format-control
              "The NIL defaults to a genpath-function's &OPTIONALs must be at the end")
        (error "The NILs to a genpath-function's &OPTIONALs must be at the end")))))

(defun make-genpath-form (genpath-fn-name resource-sym lambda-list)
  (multiple-value-bind (required optional rest kwargs aok-p aux key-p)
      (alexandria:parse-ordinary-lambda-list lambda-list)
    (declare (ignore aux key-p))
    (let* (;;
           ;;
           (augmented-optional
             (loop for (name default nil) in optional
                   collect `(,name ,default ,(gensym))))
           ;;
           ;;
           (augmented-kwargs
             (loop for (kw-and-sym default) in kwargs
                   collect `(,kw-and-sym ,default ,(gensym))))
           ;;
           ;;
           (all-kwargs
             augmented-kwargs)
           ;;
           ;;
           (required-args-form
             `(list ,@required))
           ;;
           ;;
           (optional-args-form
             `(list ,@(loop for (name default supplied-p) in augmented-optional
                            collect `(if ,supplied-p ,name (or ,name ,default)))))
           ;;
           ;;
           (keyword-arguments-form
             `(alexandria:flatten
               (remove-if #'null
                          (list
                           ,@(loop for (kw-and-sym default supplied-p)
                                     in augmented-kwargs
                                   for (nil sym) = kw-and-sym
                                   collect `(list (intern (symbol-name ',sym) (find-package :KEYWORD))
                                                  (if ,supplied-p
                                                      ,sym
                                                      (or ,sym
                                                          ,default)))))
                          :key #'second))))
      ;; Optional args are checked at macroexpansion time
      ;;
      (check-optional-args (mapcar #'second optional) 'warn-p)
      `(defun ,genpath-fn-name
           ,@`(;; Nasty, this could easily be a function.
               ;; 
               (,@required
                &optional
                  ,@augmented-optional
                  ,@(if rest
                        (warn 'style-warning
                              :format-control "&REST ~a is not supported for genpath-functions"
                              :format-arguments (list rest)))
                &key
                  ,@all-kwargs
                  ,@(if aok-p `(&allow-other-keys)))
               ;; And at runtime...
               ;;
               (check-optional-args ,optional-args-form)
               (convert-arguments-for-client
                (find-resource ',resource-sym)
                (append
                 ,required-args-form
                 (remove nil ,optional-args-form))
                ,keyword-arguments-form))))))

(defun defroute-1 (name args)
  (let* (;; find the qualifiers and lambda list
         ;; 
         (first-parse
           (multiple-value-list
            (parse-defroute-args args)))
         (qualifiers (first first-parse))
         (lambda-list (second first-parse))
         (body (third first-parse))
         ;; now parse body
         ;; 
         (parsed-body (multiple-value-list (alexandria:parse-body body)))
         (remaining (first parsed-body))
         (declarations (second parsed-body))
         (docstring (third parsed-body))
         ;; Add syntactic sugar for the first two specializers in the
         ;; lambda list
         ;; 
         (verb-spec (verb-spec-or-lose (first lambda-list)))
         (type-spec (content-type-spec-or-lose (second lambda-list) (second verb-spec)))
         (proper-lambda-list
           `(,verb-spec ,type-spec ,@(nthcdr 2 lambda-list)))
         (simplified-lambda-list
           (mapcar #'ensure-atom proper-lambda-list)))
    `(progn
       (unless (find-resource ',name)
         (defresource ,name ,simplified-lambda-list))
       (defmethod ,name ,@qualifiers
         ,proper-lambda-list
         ,@(if docstring `(,docstring))
         ,@declarations
         ,@remaining))))

(defun defresource-1 (name lambda-list options)
  (let* ((genpath-form)
         (defgeneric-args
           (loop for option in options
                 for routep = (eq :route (car option))
                 for (qualifiers spec-list body)
                   = (and routep
                          (multiple-value-list
                           (parse-defroute-args (cdr option))))
                 for verb-spec = (and routep
                                      (verb-spec-or-lose (first spec-list)))
                 for type-spec = (and routep
                                      (content-type-spec-or-lose (second spec-list)
                                                                 (second verb-spec)))
                 
                 if routep
                   collect `(:method
                              ,@qualifiers
                              (,verb-spec ,type-spec ,@(nthcdr 2 spec-list))
                              ,@body)
                 else if (eq :genpath (car option))
                        do (setq genpath-form
                                 (make-genpath-form (second option) name
                                                    (nthcdr 2 lambda-list)))
                 else
                   collect option))
         (simplified-lambda-list (mapcar #'(lambda (argspec)
                                             (ensure-atom argspec))
                                         lambda-list)))
    `(progn
       ,@(if genpath-form `(,genpath-form))
       (defgeneric ,name ,simplified-lambda-list
         (:generic-function-class resource-generic-function)
         ,@defgeneric-args))))


;;; Some external stuff but hidden away from the main file
;;; 

(defmethod explain-condition (condition resource (content-type (eql 'failsafe)))
  (declare (ignore resource))
  (format nil "~a" condition))

(defmethod explain-condition (condition resource (content-type (eql 'full-backtrace)))
  (declare (ignore resource))
  (format nil "Your SNOOZE was bitten by:~&~a"
          (with-output-to-string (s)
            (uiop/image:print-condition-backtrace condition :stream s))))

(defmethod explain-condition (condition resource (content-type snooze-types:text/plain))
  (explain-condition condition resource 'failsafe))

(define-condition http-condition (simple-condition)
  ((status-code :initarg :status-code :initform (error "Must supply a HTTP status code.")
                :reader status-code))
  (:default-initargs :format-control "HTTP condition"))

(define-condition http-error (http-condition simple-error) ()
  (:default-initargs
   :format-control "HTTP Internal Server Error"
   :status-code 500))

(define-condition no-such-resource (http-condition) ()
  (:default-initargs
   :status-code 404
   :format-control "Resource does not exist"))

(define-condition invalid-resource-arguments (http-condition) ()
  (:default-initargs
   :status-code 400
   :format-control "Resource exists but invalid arguments passed"))

(define-condition unconvertible-argument (invalid-resource-arguments)
  ((unconvertible-argument-value :initarg :unconvertible-argument-value :accessor unconvertible-argument-value)
   (unconvertible-argument-key :initarg :unconvertible-argument-key :accessor unconvertible-argument-key))
  (:default-initargs
   :status-code 400
   :format-control "An argument in the URI cannot be read"))

(define-condition  unsupported-content-type (http-error) ()
  (:default-initargs
   :status-code 501
   :format-control "Resource exists but invalid arguments passed"))


;;; More internal stuff
;;; 

(define-condition no-such-route (http-condition) ()
  (:default-initargs
   :format-control "Resource exists but no such route"))

(defmethod initialize-instance :after ((e http-error) &key)
  (assert (<= 500 (status-code e) 599) nil
          "An HTTP error must have a status code between 500 and 599"))

(defun matching-content-type-or-lose (resource verb args try-list)
  "Check RESOURCE for route matching VERB, TRY-LIST and ARGS.
TRY-LIST, a list of subclasses of SNOOZE-TYPES:CONTENT, is iterated.
The first subclass for which RESOURCE has a matching specializer is
used to create an instance, which is returned. If none is found error
out with NO-SUCH-ROUTE."
  (or (some (lambda (maybe)
              (when (gf-primary-method-specializer
                     resource
                     (list* verb maybe args)
                     1)
                maybe))
            (mapcar #'make-instance try-list))
      (error 'no-such-route
             :status-code (if (destructive-p verb)
                              415 ; unsupported media type
                              406 ; not acceptable
                              ))))

(defun call-brutally-explaining-conditions (fn)
  (let (code condition)
    (flet ((explain (how)
             (throw 'response
               (values code
                       (explain-condition condition *resource* how)
                       (content-class-name 'text/plain)))))
      (restart-case (handler-bind ((error
                                     (lambda (e)
                                       (setq code 500 condition e)
                                       (cond ((eq *catch-errors* :backtrace)
                                              (invoke-restart 'explain-with-backtrace))
                                             (*catch-errors*
                                              (invoke-restart 'failsafe-explain)))))
                                   (http-condition
                                     (lambda (c)
                                       (setq code (status-code c) condition c)
                                       (cond ((eq *catch-http-conditions* :backtrace)
                                              (invoke-restart 'explain-with-backtrace))))))
                      (funcall fn))
        (explain-with-backtrace () :report
          (lambda (s) (format s "Explain ~a condition with full backtrace" code))
          (explain 'full-backtrace))
        (failsafe-explain () :report
          (lambda (s) (format s "Explain ~a condition very succintly" code))
          (explain 'failsafe))))))

(defun call-politely-explaining-conditions (client-accepts fn)
  (let (code
        condition
        accepted-type)
    (labels ((accepted-type (condition)
               (some (lambda (wanted)
                       (when (gf-primary-method-specializer
                              #'explain-condition
                              (list condition *resource* wanted)
                              1)
                         wanted))
                     (mapcar #'make-instance client-accepts)))
             (explain ()
               (throw 'response
                 (values code
                         (explain-condition condition *resource* accepted-type)
                         (content-class-name accepted-type)))))
      (restart-case 
          (handler-bind ((condition
                           (lambda (c)
                             (setq condition c
                                   accepted-type (accepted-type condition))
                             (unless accepted-type
                               (error "Cannot politely explain~%~a~%to client, who only accepts~%~a"
                                      c client-accepts))))
                         (http-condition
                           (lambda (c)
                             (setq code (status-code c))
                             (when (and *catch-http-conditions*
                                        (not (eq *catch-http-conditions* :backtrace)))
                               (invoke-restart 'politely-explain))))
                         (error
                           (lambda (e)
                             (declare (ignore e))
                             (setq code 501)
                             (when (and *catch-errors*
                                        (not (eq *catch-errors* :backtrace)))
                               (invoke-restart 'politely-explain)))))
            (funcall fn))
        (politely-explain ()
          :report (lambda (s)
                    (format s "Politely explain to client in ~a"
                            accepted-type))
          :test (lambda (c) (declare (ignore c)) accepted-type)
          (explain))
        (auto-catch ()
          :report (lambda (s)
                    (format s "Start catching ~a automatically"
                            (if (typep condition 'http-condition)
                                "HTTP conditions" "errors")))
          :test (lambda (c)
                  (if (typep c 'http-condition)
                      (not *catch-http-conditions*)
                      (not *catch-errors*)))
          (if (typep condition 'http-condition)
              (setq *catch-http-conditions* t)
              (setq *catch-errors* t))
          (if (find-restart 'politely-explain)
              (explain)
              (if (find-restart 'failsafe-explain)
                  (invoke-restart 'failsafe-explain))))))))

(defmacro brutally-explaining-conditions (() &body body)
  "Explain conditions in BODY in a failsafe way.
Honours the :BACKTRACE option to *CATCH-ERRORS* and *CATCH-HTTP-CONDITIONS*."
  `(call-brutally-explaining-conditions (lambda () ,@body)))

(defmacro politely-explaining-conditions ((client-accepts) &body body)
  "Explain conditions in BODY taking the client accepts into account.
Honours *CATCH-ERRORS* and *CATCH-HTTP-CONDITIONS*"
  `(call-politely-explaining-conditions ,client-accepts (lambda () ,@body)))

(defvar *resource*
  "Bound early in HANDLE-REQUEST-1 to nil or to a RESOURCE.
Used by POLITELY-EXPLAINING-CONDITIONS and
BRUTALLY-EXPLAINING-CONDITIONS to pass a resource to
EXPLAIN-CONDITION.")

(defun handle-request-1 (uri method accept content-type)
  (catch 'response
    (let (*resource*
          uri-content-classes
          relative-uri)
      (brutally-explaining-conditions ()
        (multiple-value-setq (*resource* uri-content-classes relative-uri)
          (parse-resource uri))
        (let* ((verb (find-verb-or-lose method))
               (client-accepted-content-types
                 (or (append uri-content-classes
                             (content-classes-in-accept-string accept))
                     (list (find-content-class 'snooze-types:text/plain)))))
          (politely-explaining-conditions (client-accepted-content-types)
            (unless *resource*
              (error 'no-such-resource
                     :format-control
                     "So sorry, but that URI doesn't match any REST resources"))
            ;; URL-decode args to strings
            ;;
            (multiple-value-bind (converted-plain-args converted-keyword-args)
                (uri-to-arguments *resource* relative-uri)
              (let ((converted-arguments (append converted-plain-args converted-keyword-args)))
                ;; This is a double check that the arguments indeed
                ;; fit the resource's lambda list
                ;; 
                (unless (arglist-compatible-p *resource* converted-arguments)
                  (error 'invalid-resource-arguments
                         :format-control
                         "Too many, too few, or unsupported query arguments for REST resource ~a"
                         :format-arguments
                         (list (resource-name *resource*))))
                (let* ((content-types-to-try
                         (etypecase verb
                           (snooze-verbs:sending-verb client-accepted-content-types)
                           (snooze-verbs:receiving-verb
                            (list (or (and uri-content-classes
                                           (first uri-content-classes))
                                      (parse-content-type-header content-type)
                                      (error 'unsupported-content-type))))))
                       (matching-ct
                         (matching-content-type-or-lose *resource*
                                                        verb
                                                        converted-arguments
                                                        content-types-to-try)))
                  (multiple-value-bind (payload code payload-ct)
                      (apply *resource* verb matching-ct converted-arguments)
                    (unless code
                      (setq code (if payload
                                     200 ; OK
                                     204 ; OK, no content
                                     )))
                    (cond (payload-ct
                           (when (and (destructive-p verb)
                                      (not (typep payload-ct (class-of matching-ct))))
                             (warn "Route declared ~a as a its payload content-type, but it matched ~a"
                                   payload-ct matching-ct)))
                          (t
                           (setq payload-ct
                                 (if (destructive-p verb)
                                     'snooze-types:text/html ; the default
                                     matching-ct))))
                    (throw 'response (values code
                                             payload
                                             (content-class-name payload-ct)))))))))))))

(defmethod uri-to-arguments (resource relative-uri)
  "Default method of URI-TO-ARGUMENTS, which see."
  (declare (ignore resource))
  (flet ((probe (str &optional key)
           (handler-case
               (progn
                 (slynk-trace-dialog:trace-format "probing ~a" str)
                 (let ((*read-eval* nil)
                       (*package* #.(find-package "KEYWORD")))
                   (read-from-string str)))
             (error (e)
               (error 'unconvertible-argument
                      :unconvertible-argument-value str
                      :unconvertible-argument-key key
                      :format-control "Malformed arg for resource ~a: ~a"
                      :format-arguments (list (resource-name *resource*) e))))))
    (when relative-uri
      (let* ((relative-uri (ensure-uri relative-uri))
             (path (quri:uri-path relative-uri))
             (query (quri:uri-query relative-uri))
             (fragment (quri:uri-fragment relative-uri))
             (plain-args (and path
                              (plusp (length path))
                              (cl-ppcre:split "/" (subseq path 1))))
             (keyword-args (append
                            (and query
                                 (loop for maybe-pair in (cl-ppcre:split "[;&]" query)
                                       for (undecoded-key-name undecoded-value-string) = (scan-to-strings* "(.*)=(.*)" maybe-pair)
                                       when (and undecoded-key-name undecoded-value-string)
                                         append (list (intern (string-upcase
                                                               (quri:url-decode undecoded-key-name))
                                                              :keyword)
                                                      (quri:url-decode undecoded-value-string))))
                            (when fragment
                              (list 'snooze:fragment fragment)))))
        (values
         (mapcar #'probe (mapcar #'quri:url-decode plain-args))
         (loop for (key value) on keyword-args by #'cddr
               collect key
               collect (probe value key)))))))

(defmethod arguments-to-uri (resource plain-args keyword-args)
  (flet ((encode (thing)
           (quri:url-encode
            (cond ((keywordp thing)
                   (string-downcase thing))
                  (t
                   (let ((*package* #.(find-package "KEYWORD"))
                         (*print-case* :downcase))
                     (write-to-string thing)))))))
  (let* ((plain-part (format nil "/~{~a~^/~}"
                                (mapcar #'encode plain-args)))
         (query-part (and keyword-args
                          (format nil "?~{~a=~a~^&~}" (mapcar #'encode keyword-args)))))
    (let ((string (format nil "/~a~a~a"
                          (string-downcase (resource-name resource))
                          (or plain-part "")
                          (or query-part ""))))
      string))))

(defun default-resource-name (uri)
  "Default value for *RESOURCE-NAME-FUNCTION*, which see."
  (let* ((first-slash-or-qmark (position-if #'(lambda (char)
                                                (member char '(#\/ #\?)))
                                            uri
                                            :start 1)))
    (values (cond (first-slash-or-qmark
                   (subseq uri 1 first-slash-or-qmark))
                  (t
                   (subseq uri 1)))
            (if first-slash-or-qmark
                (subseq uri first-slash-or-qmark)))))

(defun search-for-extension-content-type (uri-path)
  "Default value for *URI-CONTENT-TYPES-FUNCTION*, which see."
  (multiple-value-bind (matchp groups)
      (cl-ppcre:scan-to-strings "([^\\.]+)\\.(\\w+)(.*)" uri-path)
    (let ((content-type-class (and matchp
                                   (find-content-class
                                    (gethash (aref groups 1) *mime-type-hash*)))))
      (when content-type-class
        (values
         (list content-type-class)
         (format nil "~a~a" (aref groups 0) (aref groups 2)))))))

(defun all-defined-resources ()
  "Default value for *RESOURCES-FUNCTION*, which see."
  snooze-common:*all-resources*)

