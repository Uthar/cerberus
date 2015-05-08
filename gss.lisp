;;;; Copyright (c) Frank James 2015 <frank.a.james@gmail.com>
;;;; This code is licensed under the MIT license.

;;; This file contains the codes necessary to wrap the underlying
;;; kerberos calls in a gss-like API
;;; 

(in-package #:cerberus)


;; gss requires us to encode a structure to put into the checksum of the authenticator 
;; the checksum type is #x8003 (see rfc1964 sec 1.1.1)
;; (defun encode-gss-checksum ()
;;   (flexi-streams:with-output-to-sequence (s)
;;     (nibbles:write-ub32/le 16 s) ;; length of bind field
;;     ;; md5 hash of channel bindings
;;     ;; flags

    



;; -------------------- for everyone ------------
;; everyone calls this, but the semantics are different if you are a server or client 

(defclass kerberos-context ()
  ((creds :initarg :creds :initform nil :accessor kerberos-context-creds)
   (req :initarg :req :initform nil :accessor kerberos-context-req)
   (buffer :initform nil :initarg :buffer :accessor kerberos-context-buffer)
   (key :initform nil :accessor kerberos-context-key)
   (seqno :initform 0 :accessor kerberos-context-seqno)
   (initiator :initform nil :initarg :initiator :accessor kerberos-context-initiator)))

(defmethod glass:acquire-credential ((mech-type (eql :kerberos)) principal 
				   &key username password realm kdc-address till-time)
  (cond
    ((and kdc-address username password realm)
     ;; client logging into the domain
     (let ((tgt (request-tgt username password realm 
			      :kdc-address kdc-address
			      :till-time till-time)))
       (let ((creds (request-credentials tgt principal :till-time till-time)))
	 (make-instance 'kerberos-context
			:creds creds
			:initiator t))))
    ((and (not kdc-address) username password realm)
     ;; application server generatigna keylist
     (make-instance 'kerberos-context
		    :creds (generate-keylist username password realm)))
    (realm
     ;; try to get a tgt we already have
     (let ((tgt (find-if (lambda (tgt)
			   (string= (login-token-realm tgt) realm))
			 *tgt-cache*)))
       (unless tgt (error "No TGT for the specified user, login by providing user credentials."))
       (let ((creds (request-credentials tgt principal :till-time till-time)))
	 (make-instance 'kerberos-context
			:creds creds
			:initiator t))))
    (t (error "must provide a realm"))))

;; ----------- for the client ---------------
      
(defmethod glass:initialize-security-context ((context kerberos-context) &key mutual)
  (let* ((req (make-ap-request (kerberos-context-creds context) 
			       :mutual mutual
			       :seqno (kerberos-context-seqno context))) ;; FIXME: also need the checksum!
	 (buffer (pack-initial-context-token req)))
    (setf (kerberos-context-req context) req
	  (kerberos-context-buffer context) buffer
	  (kerberos-context-key context)
	  ;; the session key can be found in the crednetials (which is a kdc-rep)
	  (enc-kdc-rep-part-key (kdc-rep-enc-part (kerberos-context-creds context))))
    buffer))
	  
;; ---------- for the application server -----------

(defmethod glass:accept-security-context ((context kerberos-context) buffer &key)
  (let ((ap-req (unpack-initial-context-token buffer)))
    (setf (kerberos-context-req context) 
	  (valid-ticket-p (kerberos-context-creds context) ap-req)
	  (kerberos-context-key context) 
	  (enc-ticket-part-key (ticket-enc-part (ap-req-ticket ap-req))))
    context))

;; this is for context deletion, do we need it?
;;(defgeneric gss-process-context-token (mech-type context &key)
;;  (:documentation "CONTEXT is returned from ACCEPT-SECURITY-CONTEXT. c.f. GSS_Process_context_token"))

;; ------------------ per-message calls --------------------------

;; the context handle MUST be the kdc-rep i.e. the "credentials" that were passed into the initialize-context
(defmethod glass:get-mic ((context kerberos-context) message &key)
  (let* ((req (kerberos-context-req context))
	 (session-key (kerberos-context-key context))
	 (key (subseq (encryption-key-value session-key) 0 8))
	 (initiator (kerberos-context-initiator context))
	 (message (concatenate '(vector (unsigned-byte 8)) message)))
    (pack-initial-context-token 
     (flexi-streams:with-output-to-sequence (s)
       (write-sequence '(1 1) s) ;; TOK_ID == getmic
       (write-sequence '(0 0) s) ;; SGN_ALG == DES MAC MD5
       (write-sequence '(#xff #xff #xff #xff) s) ;; filler
       
       (let ((cksum (des-mac (md5 message)
			     nil
			     key))) 
	 
	 ;; write the ap-req seqno
	 (let ((seqno (if (kerberos-context-initiator context)
			  ;; we are the client, we store our own seqno
			  (kerberos-context-seqno context)
			  ;; the seqno can be found in the authenticator 
			  (authenticator-seqno (ap-req-authenticator req)))))
	   (unless seqno (error "Seqno is mandatory for GSS"))
	   (let ((bytes (concatenate '(vector (unsigned-byte 8)) 
				     (let ((v (nibbles:make-octet-vector 4)))
				       (setf (nibbles:ub32ref/be v 0) seqno)
				       v)
				     (if initiator '(0 0 0 0) '(#xff #xff #xff #xff)))))
	     (write-sequence (encrypt-des-cbc key 
					      bytes
					      :initialization-vector (subseq cksum 0 8))
			     s)))
	 ;; write the checksum 
	 (write-sequence cksum s))))))
  
(defmethod glass:verify-mic ((context kerberos-context) message message-token &key initiator)
  (let* ((req (kerberos-context-req context))
	 (tok (unpack-initial-context-token message-token))
	 (session-key (ap-req-session-key req))
	 (key (subseq (encryption-key-value session-key) 0 8))
	 (message (concatenate '(vector (unsigned-byte 8)) message)))
    ;; start by getting the checksum and seqno fields
    (let ((seqno (subseq tok 8 16))
	  (cksum (subseq tok 16 24))
	  (the-cksum (des-mac (md5 message) nil key)))
      ;; compare the checksums
      (unless (equalp cksum the-cksum) (error 'checksum-error))
      ;; decrypt the seqno
      (let ((sq (decrypt-des-cbc key seqno :initialization-vector (subseq the-cksum 0 8))))
	(every #'= 
	       sq 
	       (concatenate '(vector (unsigned-byte 8)) 
			    (let ((v (nibbles:make-octet-vector 4)))
			      (setf (nibbles:ub32ref/be v 0) (authenticator-seqno (ap-req-authenticator req)))
			      v)
			    (if (not initiator) '(0 0 0 0) '(#xff #xff #xff #xff))))))))

;; context handle is the ap-req 
(defmethod glass:wrap ((context kerberos-context) message &key)   
  (let* ((req (kerberos-context-req context))
	 (session-key (subseq (encryption-key-value (kerberos-context-key context))
			      0 8))
	 (initiator (kerberos-context-initiator context))
	 (message (concatenate '(vector (unsigned-byte 8)) message)))
    ;; start by padding the message
    (let* ((len (length message))
	   (msg (concatenate '(vector (unsigned-byte 8))
			     (loop :for i :below 8 :collect (random 256)) ;; confounder 
			     message
			     (unless (zerop (mod len 8)) ;; padding 
			       (loop :for i :below (- 8 (mod len 8)) :collect (- 8 (mod len 8))))))
	   (key (map '(vector (unsigned-byte 8)) 
		     (lambda (x) (logxor x #xf0))
		     session-key))
	   (cksum (des-mac (md5 msg) ;;message)
			     nil
			     session-key))
	   (seqno (encrypt-des-cbc session-key 
				   (concatenate '(vector (unsigned-byte 8)) 
						(let ((v (nibbles:make-octet-vector 4)))
						  (setf (nibbles:ub32ref/be v 0)
							(if initiator
							    (kerberos-context-seqno context)
							    (authenticator-seqno (ap-req-authenticator req))))
						  v)
						(if initiator '(0 0 0 0) '(#xff #xff #xff #xff)))
				   :initialization-vector (subseq cksum 0 8))))
	         
    (pack-initial-context-token 
     (flexi-streams:with-output-to-sequence (s)
       (write-sequence '(2 1) s) ;; TOK_ID 
       (write-sequence '(0 0) s) ;; sgn_alg == des mac md5
       (write-sequence '(0 0) s) ;; seal_alg == des
       (write-sequence '(#xff #xff) s) ;; filler
       ;; encrypted seqno field
       (write-sequence seqno s)
       ;; checksum
       (write-sequence cksum s)
       ;; encrypted body
       (write-sequence (encrypt-des-cbc key msg) s))))))

(defmethod glass:unwrap ((context kerberos-context) buffer &key)
  ;; start by extracting the token from the buffer
  (let* ((tok (unpack-initial-context-token buffer))
	 (req (kerberos-context-req context))
	 (session-key (subseq (encryption-key-value (kerberos-context-key context))
			      0 8))
	 (initiator (kerberos-context-initiator context)))
    ;; get the seqno, cksum and encrypted body
    (let ((eseqno (subseq tok 8 16))
	  (cksum (subseq tok 16 24))
	  (emsg (subseq tok 24))
	  (key (map '(vector (unsigned-byte 8)) 
		    (lambda (x) (logxor x #xf0))
		    session-key)))
      ;; start by decrypting the body
      (let* ((msg (decrypt-des-cbc key emsg))
	     (message (subseq msg 8))) ;; drop the confounder 
	;; compute the checksum
	(let ((the-cksum (des-mac (md5 msg) ;;message)
				  nil
				  session-key)))
	  ;; validate the checksums match
	  (unless (equalp cksum the-cksum) (error 'checksum-error))
	  ;; now decrypt the seqno
	  (let ((seqno (decrypt-des-cbc session-key
					eseqno
					:initialization-vector (subseq the-cksum 0 8))))
	    ;; check the seqnos match
	    (unless (equalp seqno
			    (concatenate '(vector (unsigned-byte 8))
					 (let ((v (nibbles:make-octet-vector 4)))
					   (setf (nibbles:ub32ref/be v 0) 
						 (if initiator
						     (kerberos-context-seqno context)
						     (authenticator-seqno (ap-req-authenticator req))))
					   v)
					 (if (not initiator) '(0 0 0 0) '(#xff #xff #xff #xff))))
	      (error "Seqnos don't match"))))
	;; return the decrypted message
	message))))
      
  
