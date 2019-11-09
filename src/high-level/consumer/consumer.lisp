;;; Copyright (C) 2018-2019 Sahil Kang <sahil.kang@asilaycomputing.com>
;;;
;;; This file is part of cl-rdkafka.
;;;
;;; cl-rdkafka is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; cl-rdkafka is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with cl-rdkafka.  If not, see <http://www.gnu.org/licenses/>.

(in-package #:cl-rdkafka)

(defclass consumer ()
  ((rd-kafka-consumer
    :documentation "Pointer to rd_kafka_t struct.")
   (key-serde
    :initform nil
    :documentation "Function to map byte vector to object, or nil for bytes.")
   (value-serde
    :initform nil
    :documentation "Function to map byte vector to object, or nil for bytes."))
  (:documentation
   "A client that consumes messages from kafka topics.

Example:

(let* ((string-serde (lambda (x)
                       (babel:octets-to-string x :encoding :utf-8)))
       (conf (kf:conf
              \"bootstrap.servers\" \"127.0.0.1:9092\"
              \"group.id\" \"consumer-group-id\"
              \"enable.auto.commit\" \"false\"
              \"auto.offset.reset\" \"earliest\"
              \"offset.store.method\" \"broker\"
              \"enable.partition.eof\"  \"false\"))
       (consumer (make-instance 'kf:consumer
                                :conf conf
                                :serde string-serde)))
  (kf:subscribe consumer '(\"topic-name\"))

  (loop
     for message = (kf:poll consumer (* 2 1000))
     while message

     for key = (kf:key message)
     for value = (kf:value message)

     collect (list key value)

     do (kf:commit consumer)))"))

(defgeneric subscribe (consumer topics)
  (:documentation
   "Subscribe consumer to sequence of topic names."))

(defgeneric unsubscribe (consumer)
  (:documentation
   "Unsubscribe consumer from its current topic subscription."))

(defgeneric subscription (consumer)
  (:documentation
   "Return a list of topic names that CONSUMER is subscribed to."))

(defgeneric poll (consumer timeout-ms)
  (:documentation
   "Block for up to timeout-ms milliseconds and return a kf:message or nil"))

(defgeneric commit (consumer &optional topic+partitions)
  (:documentation
   "Commit offsets to broker.

TOPIC+PARTITIONS is an alist with elements that look like one of:
  * ((topic . partition) . offset)
  * ((topic . partition) . (offset . metadata))

If TOPIC+PARTITIONS is nil (the default) then the current assignment
is committed."))

(defgeneric committed (consumer &optional topic+partitions)
  (:documentation
   "Return an alist of committed topic+partitions.

TOPIC+PARTITIONS is an alist with elements that look like:
  * (topic . partition)

If TOPIC+PARTITIONS is nil (the default) then info about the current
assignment is returned.

The returned alist has elements that look like:
  * ((topic . partition) . (offset . metadata))"))

(defgeneric assignment (consumer)
  (:documentation
   "Get a sequence of assigned topic+partitions."))

(defgeneric assign (consumer topic+partitions)
  (:documentation
   "Assign partitions to consumer."))

(defgeneric member-id (consumer)
  (:documentation
   "Return CONSUMER's broker-assigned group member-id."))

(defgeneric pause (consumer topic+partitions)
  (:documentation
   "Pause consumption from the TOPIC+PARTITIONS alist."))

(defgeneric resume (consumer topic+partitions)
  (:documentation
   "Resume consumption from the TOPIC+PARTITIONS alist."))

(defgeneric query-watermark-offsets (consumer topic partition &key timeout-ms)
  (:documentation
   "Query broker for low (oldest/beginning) and high (newest/end) offsets.

A (low high) list is returned."))

(defgeneric offsets-for-times (consumer timestamps &key timeout-ms)
  (:documentation
   "Look up the offsets for the given partitions by timestamp.

The returned offset for each partition is the earliest offset whose
timestamp is greater than or equal to the given timestamp in the
corresponding partition.

TIMESTAMPS is an alist with elements that look like:
  ((\"topic\" . partition) . timestamp)

and the returned alist contains elements that look like:
  ((\"topic\" . partition) . offset)"))

(defgeneric positions (consumer topic+partitions)
  (:documentation
   "Retrieve current positions (offsets) for TOPIC+PARTITIONS.

TOPIC+PARTITIONS is an alist with elements that look like:
  (\"topic\" . partition)

and the returned alist contains elements that look like (offset will
be nil if no previous message existed):
  ((\"topic\" . partition) . offset)"))

(defmethod initialize-instance :after
    ((consumer consumer) &key conf serde key-serde value-serde)
  (with-slots (rd-kafka-consumer (ks key-serde) (vs value-serde)) consumer
    (cffi:with-foreign-object (errstr :char +errstr-len+)
      (setf rd-kafka-consumer (cl-rdkafka/ll:rd-kafka-new
                               cl-rdkafka/ll:rd-kafka-consumer
                               (make-conf conf)
                               errstr
                               +errstr-len+))
      (when (cffi:null-pointer-p rd-kafka-consumer)
        (error "~&Failed to allocate new consumer: ~A"
               (cffi:foreign-string-to-lisp errstr :max-chars +errstr-len+))))
    (setf ks (or key-serde serde)
          vs (or value-serde serde))
    (tg:finalize
     consumer
     (lambda ()
       (cl-rdkafka/ll:rd-kafka-consumer-close rd-kafka-consumer)
       (cl-rdkafka/ll:rd-kafka-destroy rd-kafka-consumer)))))

(defmethod subscribe ((consumer consumer) topics)
  (with-slots (rd-kafka-consumer) consumer
    (let ((rd-kafka-list (topic+partitions->rd-kafka-list
                          (map 'list
                               (lambda (name)
                                 (make-instance 'topic+partition :topic name))
                               topics))))
      (unwind-protect
           (let ((err (cl-rdkafka/ll:rd-kafka-subscribe rd-kafka-consumer
                                                        rd-kafka-list)))
             (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
               (error "~&Failed to subscribe to topics with error: ~S"
                      (cl-rdkafka/ll:rd-kafka-err2str err))))
        (cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy rd-kafka-list)))))

(defmethod unsubscribe ((consumer consumer))
  (with-slots (rd-kafka-consumer) consumer
    (let ((err (cl-rdkafka/ll:rd-kafka-unsubscribe rd-kafka-consumer)))
      (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
        (error "~&Failed to unsubscribe consumer with error: ~S"
               (cl-rdkafka/ll:rd-kafka-err2str err))))))

(define-condition subscription-error (error)
  ((description
    :initarg :description
    :initform (error "Must supply description.")
    :reader description))
  (:report
   (lambda (c s)
     (format s "~&Subscription Error: ~S" (description c))))
  (:documentation
   "Condition signalled when consumer's subscription method fails."))

(defun %subscription (rd-kafka-consumer)
  (cffi:with-foreign-object (rd-list :pointer)
    (let ((err (cl-rdkafka/ll:rd-kafka-subscription
                rd-kafka-consumer
                rd-list)))
      (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
        (error 'subscription-error
               :description (cl-rdkafka/ll:rd-kafka-err2str err)))
      (cffi:mem-ref rd-list :pointer))))

(defmethod subscription ((consumer consumer))
  (with-slots (rd-kafka-consumer) consumer
    (let ((rd-list (%subscription rd-kafka-consumer)))
      (unwind-protect
           (let (return-me)
             (foreach-toppar rd-list (topic)
               (push topic return-me))
             return-me)
        (cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy rd-list)))))

(defmethod poll ((consumer consumer) (timeout-ms integer))
  (with-slots (rd-kafka-consumer key-serde value-serde) consumer
    (let (rd-kafka-message)
      (unwind-protect
           (progn
             (setf rd-kafka-message (cl-rdkafka/ll:rd-kafka-consumer-poll
                                     rd-kafka-consumer
                                     timeout-ms))
             (when (cffi:null-pointer-p rd-kafka-message)
               (setf rd-kafka-message nil))
             (when rd-kafka-message
               (restart-case
                   (rd-kafka-message->message rd-kafka-message
                                              key-serde
                                              value-serde)
                 (use-value (value)
                   :report "Specify a value to return from poll."
                   :interactive (lambda ()
                                  (format t "Enter a value to return: ")
                                  (list (read)))
                   value))))
        (when rd-kafka-message
          (cl-rdkafka/ll:rd-kafka-message-destroy rd-kafka-message))))))

(define-condition commit-error (error)
  ((description
    :initarg :description
    :initform (error "Must supply description.")
    :reader description))
  (:report
   (lambda (c s)
     (format s "~&Commit Error: ~S" (description c))))
  (:documentation
   "Condition signalled when consumer's commit method fails."))

(defun %commit (rd-kafka-consumer rd-kafka-topic-partition-list)
  (unwind-protect
       (let ((err (cl-rdkafka/ll:rd-kafka-commit
                   rd-kafka-consumer
                   rd-kafka-topic-partition-list
                   0)))
         (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
           (error 'commit-error
                  :description (cl-rdkafka/ll:rd-kafka-err2str err))))
    (unless (cffi:null-pointer-p rd-kafka-topic-partition-list)
      (cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy
       rd-kafka-topic-partition-list))))

(defmethod commit ((consumer consumer) &optional topic+partitions)
  (with-slots (rd-kafka-consumer) consumer
    (restart-case
        (if topic+partitions
            (%commit rd-kafka-consumer
                     (topic+partitions->rd-kafka-list
                      (mapcar
                       (lambda (pair)
                         (destructuring-bind
                               ((topic . partition) . maybe-pair) pair
                           (if (consp maybe-pair)
                               (make-instance 'topic+partition
                                              :topic topic
                                              :partition partition
                                              :offset (car maybe-pair)
                                              :metadata (cdr maybe-pair))
                               (make-instance 'topic+partition
                                              :topic topic
                                              :partition partition
                                              :offset maybe-pair))))
                       topic+partitions)))
            (%commit rd-kafka-consumer
                     (cffi:null-pointer)))
      (continue ()
        :report "Return from commit as if it did not signal a condition."))))

(defun %assignment (rd-kafka-consumer)
  (cffi:with-foreign-object (rd-list :pointer)
    (let ((err (cl-rdkafka/ll:rd-kafka-assignment rd-kafka-consumer rd-list)))
      (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
        (error "~&Failed to get assignment: ~S"
               (cl-rdkafka/ll:rd-kafka-err2str err)))
      (cffi:mem-ref rd-list :pointer))))

(defmethod assignment ((consumer consumer))
  (with-slots (rd-kafka-consumer) consumer
    (let ((rd-list (%assignment rd-kafka-consumer)))
      (unwind-protect
           (rd-kafka-list->topic+partitions rd-list)
        (cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy rd-list)))))

(defmethod committed ((consumer consumer) &optional topic+partitions)
  (with-slots (rd-kafka-consumer) consumer
    (let ((rd-list (if topic+partitions
                       (topic+partitions->rd-kafka-list
                        (mapcar (lambda (pair)
                                  (destructuring-bind (topic . partition) pair
                                    (make-instance 'topic+partition
                                                   :topic topic
                                                   :partition partition)))
                                topic+partitions))
                       (%assignment rd-kafka-consumer))))
      (unwind-protect
           (let ((err (cl-rdkafka/ll:rd-kafka-committed
                       rd-kafka-consumer
                       rd-list
                       60000))
                 alist-to-return)
             (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
               (error "~&Failed to get committed offsets with error: ~S"
                      (cl-rdkafka/ll:rd-kafka-err2str err)))
             (foreach-toppar
                 rd-list
                 (topic partition offset metadata metadata-size err)
               (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
                 (error "~&Error getting committed offset for topic|partition ~S|~S: ~S"
                        topic
                        partition
                        (cl-rdkafka/ll:rd-kafka-err2str err)))
               (let ((meta (unless (cffi:null-pointer-p metadata)
                             (pointer->bytes metadata metadata-size))))
                 (push `((,topic . ,partition) . (,offset . ,meta))
                       alist-to-return)))
             alist-to-return)
        (cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy rd-list)))))

(define-condition assign-error (error)
  ((description
    :initarg :description
    :initform (error "Must supply description")
    :reader description))
  (:report
   (lambda (c s)
     (format s "~&Assign Error: ~S" (description c))))
  (:documentation
   "Condition signalled when consumer's assign method fails."))

(defmethod assign ((consumer consumer) topic+partitions)
  (with-slots (rd-kafka-consumer) consumer
    (let ((rd-list (topic+partitions->rd-kafka-list topic+partitions)))
      (unwind-protect
           (let ((err (cl-rdkafka/ll:rd-kafka-assign rd-kafka-consumer rd-list)))
             (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
               (error 'assign-error
                      :description (cl-rdkafka/ll:rd-kafka-err2str err))))
        (cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy rd-list)))))

(defmethod member-id ((consumer consumer))
  (with-slots (rd-kafka-consumer) consumer
    (cl-rdkafka/ll:rd-kafka-memberid rd-kafka-consumer)))

(defmethod pause ((consumer consumer) (topic+partitions list))
  (with-slots (rd-kafka-consumer) consumer
    (let ((rd-list (topic+partitions->rd-kafka-list
                    (mapcar (lambda (pair)
                              (destructuring-bind (topic . partition) pair
                                (make-instance 'topic+partition
                                               :topic topic
                                               :partition partition)))
                            topic+partitions))))
      (unwind-protect
           (let ((err (cl-rdkafka/ll:rd-kafka-pause-partitions
                       rd-kafka-consumer
                       rd-list)))
             (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
               (error "~&Failed to pause paritions: ~S"
                      (cl-rdkafka/ll:rd-kafka-err2str err)))
             ;; rd-kafka-pause-partitions will set the err field of
             ;; each struct in rd-list, so let's make sure no per
             ;; topic-partition errors occurred
             (foreach-toppar rd-list (err topic partition)
               (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
                 (error "~&Error pausing topic|partition ~S|~S: ~S"
                        topic
                        partition
                        (cl-rdkafka/ll:rd-kafka-err2str err)))))
        (cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy rd-list)))))

(defmethod resume ((consumer consumer) (topic+partitions list))
  (with-slots (rd-kafka-consumer) consumer
    (let ((rd-list (topic+partitions->rd-kafka-list
                    (mapcar (lambda (pair)
                              (destructuring-bind (topic . partition) pair
                                (make-instance 'topic+partition
                                               :topic topic
                                               :partition partition)))
                            topic+partitions))))
      (unwind-protect
           (let ((err (cl-rdkafka/ll:rd-kafka-resume-partitions
                       rd-kafka-consumer
                       rd-list)))
             (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
               (error "~&Failed to resume partitions: ~S"
                      (cl-rdkafka/ll:rd-kafka-err2str err)))
             (foreach-toppar rd-list (err topic partition)
               (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
                 (error "~&Error resuming topic|partition ~S|~S: ~S"
                        topic
                        partition
                        (cl-rdkafka/ll:rd-kafka-err2str err)))))
        (cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy rd-list)))))

(defmethod query-watermark-offsets
    ((consumer consumer)
     (topic string)
     (partition integer)
     &key (timeout-ms 5000))
  (cffi:with-foreign-objects ((low :int64) (high :int64))
    (with-slots (rd-kafka-consumer) consumer
      (let ((err (cl-rdkafka/ll:rd-kafka-query-watermark-offsets
                  rd-kafka-consumer
                  topic
                  partition
                  low
                  high
                  timeout-ms)))
        (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
          (error "~&Failed to query offsets: ~S"
                 (cl-rdkafka/ll:rd-kafka-err2str err)))
        (list (cffi:mem-ref low :int64)
              (cffi:mem-ref high :int64))))))

(defmethod offsets-for-times
    ((consumer consumer)
     (timestamps list)
     &key (timeout-ms 5000))
  (with-slots (rd-kafka-consumer) consumer
    (let ((rd-list (topic+partitions->rd-kafka-list
                    (mapcar (lambda (pair)
                              (destructuring-bind
                                    ((topic . partition) . timestamp) pair
                                (make-instance 'topic+partition
                                               :topic topic
                                               :partition partition
                                               :offset timestamp)))
                            timestamps))))
      (unwind-protect
           (let ((err (cl-rdkafka/ll:rd-kafka-offsets-for-times
                       rd-kafka-consumer
                       rd-list
                       timeout-ms))
                 alist-to-return)
             (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
               (error "~&Failed to get offsets for times: ~S"
                      (cl-rdkafka/ll:rd-kafka-err2str err)))
             (foreach-toppar rd-list (topic partition offset err)
               (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
                 (error "~&Error getting offset for topic|partition ~S|~S: ~S"
                        topic
                        partition
                        (cl-rdkafka/ll:rd-kafka-err2str err)))
               (push `((,topic . ,partition) . ,offset) alist-to-return))
             alist-to-return)
        (cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy rd-list)))))

(defmethod positions ((consumer consumer) (topic+partitions list))
  (with-slots (rd-kafka-consumer) consumer
    (let ((rd-list (topic+partitions->rd-kafka-list
                    (mapcar (lambda (pair)
                              (destructuring-bind (topic . partition) pair
                                (make-instance 'topic+partition
                                               :topic topic
                                               :partition partition)))
                            topic+partitions))))
      (unwind-protect
           (let ((err (cl-rdkafka/ll:rd-kafka-position
                       rd-kafka-consumer
                       rd-list))
                 alist-to-return)
             (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
               (error "~&Failed to get positions: ~S"
                      (cl-rdkafka/ll:rd-kafka-err2str err)))
             (foreach-toppar rd-list (topic partition offset err)
               (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
                 (error "~&Error getting position for topic|partition ~S|~S: ~S"
                        topic
                        partition
                        (cl-rdkafka/ll:rd-kafka-err2str err)))
               (push
                (cons `(,topic . ,partition)
                      (unless (= offset cl-rdkafka/ll:rd-kafka-offset-invalid)
                        offset))
                alist-to-return))
             alist-to-return)
        (cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy rd-list)))))
