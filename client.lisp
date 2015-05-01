;;;; Copyright (c) Frank James 2015 <frank.a.james@gmail.com>
;;;; This code is licensed under the MIT license.

;;; This file contains the function to talk to the KDC (to request tickets)
;;; and related function to talk to application servers.

(in-package #:cerberus)

;; ------------------ kdc ----------------------------------

(defun process-req-response (buffer)
  "Examine the response from the KDC, will either be a reply or an error"
  (let ((code (unpack #'decode-identifier buffer)))
    (ecase code
      (30 ;; error
       (let ((err (unpack #'decode-krb-error buffer)))
         (krb-error err)))
      (11 ;; as-rep
       (unpack #'decode-as-rep buffer))
      (13 ;; tgs-rep
       (unpack #'decode-tgs-rep buffer)))))

;; UDP doesn't seem very useful. Whenever I've called it I've got 
;; a "response would be too large to fit in UDP" error. Seems like TCP
;; is the way to do it.  
(defun send-req-udp (msg host &optional port)
  "Send a message to the KDC using UDP"
  (let ((socket (usocket:socket-connect host (or port 88)
					:protocol :datagram
					:element-type '(unsigned-byte 8))))
    (unwind-protect 
	 (progn
	   (usocket:socket-send socket msg (length msg))
	   (if (usocket:wait-for-input (list socket) :timeout 1 :ready-only t)
           (multiple-value-bind (buffer count) (usocket:socket-receive socket (nibbles:make-octet-vector 1024) 1024)
             (when (or (= count -1) (= count #xffffffff))
               (error "recvfrom returned -1"))
             (process-req-response buffer))
           (error "timeout")))
      (usocket:socket-close socket))))

(defun as-req-udp (kdc-host client realm &key options till-time renew-time host-addresses
                                       pa-data tickets authorization-data)
  (send-req-udp (pack #'encode-as-req 
                  (make-as-request client realm
                                   :options options
                                   :till-time till-time
                                   :renew-time renew-time
                                   :host-addresses host-addresses
                                   :encryption-types (list-all-profiles)
                                   :pa-data pa-data
                                   :tickets tickets
                                   :authorization-data authorization-data))
            kdc-host))

;; tcp
(defun send-req-tcp (msg host &optional port)
  "Send a message to the KDC using TCP"
  (let ((socket (usocket:socket-connect host (or port 88)
                                        :element-type '(unsigned-byte 8))))
    (unwind-protect 
         (let ((stream (usocket:socket-stream socket)))
           (nibbles:write-ub32/be (length msg) stream)
           (write-sequence msg stream)
           (force-output stream)
           ;; read from the stream
           (if (usocket:wait-for-input (list socket) :timeout 1 :ready-only t)
               (let* ((n (nibbles:read-ub32/be stream))
                      (buffer (nibbles:make-octet-vector n)))
                 (read-sequence buffer stream)
                 (process-req-response buffer))
               (error "timeout")))
      (usocket:socket-close socket))))

(defun as-req-tcp (kdc-host client realm &key options till-time renew-time host-addresses
                                       pa-data tickets authorization-data)
  (send-req-tcp (pack #'encode-as-req 
                  (make-as-request client realm
                                   :options options
                                   :till-time till-time
                                   :renew-time renew-time
                                   :host-addresses host-addresses
                                   :encryption-types (list-all-profiles)
                                   :pa-data pa-data
                                   :tickets tickets
                                   :authorization-data authorization-data))
            kdc-host))

;; notes: in the case of a :preauth-required error, the edata field of the error object contains a 
;; list of pa-data objcets which specify the acceptable pa-data types. 
;; a pa-data object of type 19 provides a list of etype-info2-entry structures


(defun time-from-now (&key hours days weeks years)
  "Compute the time from the current time."
  (+ (get-universal-time) 
     (if hours (* 60 60 hours) 0)
     (if days (* 60 60 24 days) 0)
     (if weeks (* 60 60 24 7 weeks) 0)
     (if years (* 60 60 24 365 years) 0)))

;; this is used to store the details of where the kdc is so we can request more tickets
(defstruct login-token 
  address 
  rep
  tgs
  user
  realm)

;;(defmethod print-object ((token login-token) stream)
;;  (print-unreadable-object (token stream :type t)
;;    (format stream ":USER ~S :REALM ~S" 
;;            (principal-name-name (login-token-user token))
;;            (login-token-realm token))))

(defvar *kdc-address* nil 
  "The address of the default KDC.")

(defun request-tgt (username password realm &key kdc-address till-time (etype :des-cbc-md5))
  "Login to the authentication server to reqest a ticket for the Ticket-granting server. Returns a LOGIN-TOKEN
structure which should be used for requests for further tickets.

USERNAME ::= username of principal to login.
PASSWORD ::= the password to use.
REALM ::= the realm we are loggin in to.

KDC-ADDRESS ::= the IP address of the KDC.
TILL-TIME ::= how long the ticket should be valid for, defaults to 6 weeks from present time.
ETYPE ::= encryption profile name to use for pre-authentication.
"
  (cond
    (kdc-address 
     (setf *kdc-address* kdc-address))
    ((not *kdc-address*) (error "Must first set *kdc-address*"))
    (t (setf kdc-address *kdc-address*)))
  (let ((key (string-to-key etype
                            password
                            (format nil "~A~A" (string-upcase realm) username)))
        (principal (principal username)))
    (let ((as-rep 
           (as-req-tcp kdc-address
                       principal
                       realm
                       :pa-data (list (pa-timestamp key etype))
                       :till-time (or till-time (time-from-now :weeks 6)))))
      ;; we need to decrypt the enc-part of the response to verify it
      ;; FIXME: need to know, e.g. the nonce that we used in the request
      (let ((enc (unpack #'decode-enc-as-rep-part 
                         (decrypt-data (kdc-rep-enc-part as-rep) 
				       (let ((e (kdc-rep-enc-part as-rep)))
					 (string-to-key (encrypted-data-type e)
							password
							(format nil "~A~A" (string-upcase realm) username)))
				       :usage :as-rep))))
        ;; should really validate the reponse here, e.g. check nonce etc.
        ;; lets just descrypt it and replace the enc-part with the decrypted enc-part 
        (setf (kdc-rep-enc-part as-rep) enc))

      ;; the return value
      (make-login-token :address *kdc-address*
                        :rep as-rep
                        :tgs (kdc-rep-ticket as-rep)
                        :user principal
                        :realm realm))))

;; this worked. I got a ticket for the principal named
(defun request-credentials (tgt server &key till-time)  
  "Request a ticket for the named principal using the TGS ticket previously requested.

Returns a KDC-REP structure."  
  (declare (type login-token tgt)
           (type principal-name server))
  (let ((token tgt))
    (let* ((as-rep (login-token-rep token))
	   (ekey (enc-kdc-rep-part-key (kdc-rep-enc-part as-rep))))
      (let ((rep (send-req-tcp 
		  (pack #'encode-tgs-req 
			(make-kdc-request 
			 (login-token-user token)
			 :type :tgs
			 :options '(:renewable :enc-tkt-in-skey)
			 :realm (login-token-realm token)
			 :server-principal server
			 :nonce (random (expt 2 32))
			 :till-time (or till-time (time-from-now :weeks 6))
			 :encryption-types (list-all-profiles) ;;(list (encryption-key-type ekey))
			 :pa-data (list (pa-tgs-req (login-token-tgs token)
						    (encryption-key-value ekey)
						    (login-token-user token)
						    (encryption-key-type ekey)))))
		  (login-token-address token))))
	;; if we got here then the response is a kdc-rep structure (for tgs)
	;; we need to decrypt the enc-part of the response to verify it
	;; FIXME: need to know, e.g. the nonce that we used in the request
	(let ((enc (unpack #'decode-enc-as-rep-part 
			   (decrypt-data (kdc-rep-enc-part rep)
					 (encryption-key-value ekey)
					 :usage :tgs-rep))))
	  ;; should really validate the reponse here, e.g. check nonce etc.
	  ;; lets just descrypt it and replace the enc-part with the decrypted enc-part 
	  (setf (kdc-rep-enc-part rep) enc))
	
	rep))))

;; unknown whether this works. Is very similar to the request-credentials function
;; so shouldn't be too hard to get working.
(defun request-renewal (tgt credentials &key till-time)
  "Request the renewal of a ticket. The CREDENTIALS should be as returned from REQUEST-CREDENTIALS."
  (declare (type login-token tgt)
           (type kdc-rep credentials))
  (let ((token tgt))
    (let* ((as-rep (login-token-rep token))
	   (ekey (enc-kdc-rep-part-key (kdc-rep-enc-part as-rep)))
	   (ticket (kdc-rep-ticket credentials))
	   (server (enc-kdc-rep-part-sname (kdc-rep-enc-part credentials))))
      (let ((rep (send-req-tcp 
		  (pack #'encode-tgs-req 
			(make-kdc-request 
			 (login-token-user token)
			 :type :tgs
			 :options '(:renewable :enc-tkt-in-skey)
			 :realm (login-token-realm token)
			 :server-principal server
			 :nonce (random (expt 2 32))
			 :till-time (or till-time (time-from-now :weeks 6))
			 :encryption-types (list-all-profiles) 
			 :pa-data (list (pa-tgs-req (login-token-tgs token)
						    (encryption-key-value ekey)
						    (login-token-user token)
						    (encryption-key-type ekey)))
			 :tickets (list ticket)))
		  (login-token-address token))))
	;; if we got here then the response is a kdc-rep structure (for tgs)
	;; we need to decrypt the enc-part of the response to verify it
	;; FIXME: need to know, e.g. the nonce that we used in the request
	(let ((enc (unpack #'decode-enc-as-rep-part 
			   (decrypt-data (kdc-rep-enc-part rep)
					 (encryption-key-value ekey)
					 :usage :tgs-rep))))
	  ;; should really validate the reponse here, e.g. check nonce etc.
	  ;; lets just descrypt it and replace the enc-part with the decrypted enc-part 
	  (setf (kdc-rep-enc-part rep) enc))
	
	rep))))

;; next stage: need to package up an AP-REQ to be sent to the application server
;; typically this message will be encapsualted in the application protocol, so we don't do any direct 
;; networking for this, just return a packed octet buffer
(defun pack-ap-req (credentials &key mutual)
  "Generate and pack an AP-REQ structure to send to the applicaiton server. CREDENTIALS should be 
credentials for the application server, as returned from a previous call to REQUEST-CREDENTIALS.

If MUTUAL is T, then mutual authentication is requested and the applicaiton server is expected to 
respond with an AP-REP structure.
"
  (declare (type kdc-rep credentials))
  (let ((ticket (kdc-rep-ticket credentials))
	(cname (kdc-rep-cname credentials))
	(key (enc-kdc-rep-part-key (kdc-rep-enc-part credentials))))
    (pack #'encode-ap-req 
	  (make-ap-req :options (when mutual '(:mutual-required))
		       :ticket ticket
		       :authenticator 
		       (encrypt-data (encryption-key-type key)
				     (pack #'encode-authenticator 
					   (make-authenticator :crealm (ticket-realm ticket)
							       :cname cname
							       :ctime (get-universal-time)
							       :cusec 0))
				     (encryption-key-value key)
				     :usage :ap-req)))))

;; --------------- application server -------------------------

(defun decrypt-ticket-enc-part (keylist ticket)
  "Decrypt the enc-part of the ticket."
  (let ((enc (ticket-enc-part ticket)))
    (let ((key (find-if (lambda (k)
			  (eq (encryption-key-type k) (encrypted-data-type enc)))
			keylist)))
      (if key 
	  (unpack #'decode-enc-ticket-part 
		  (decrypt-data enc 
				(encryption-key-value key)
				:usage :ticket))
	  (error "No key for encryption type ~S" (encrypted-data-type enc))))))

(defun valid-ticket-p (keylist ap-req)
  "Decrypt the ticket and check its contents against the authenticator. 
If the input is an opaque buffer, it is parsed into an AP-REQ strucutre. 
Alternatively, the input may be a freshly parsed AP-REQ structure. The encrypted parts must still be encrypted, 
they will be decrypted and examined by this function.

Returns the modifed AP-REQ structure, with enc-parts replaced with decrypted versions."
  ;; if the input is a packed buffer then unpack it 
  (when (typep ap-req 'vector)
    (setf ap-req (unpack #'decode-ap-req ap-req)))

  (let ((ticket (ap-req-ticket ap-req))
	(enc-auth (ap-req-authenticator ap-req)))
    ;; start by decrypting the ticket to get the session key 
    (let ((enc (decrypt-ticket-enc-part keylist ticket)))
      (setf (ticket-enc-part ticket) enc)
      
      (let ((key (enc-ticket-part-key enc)))
	;; now decrypt the authenticator using the session key we got from the ticket
	(let ((a (decrypt-data enc-auth (encryption-key-value key)
			       :usage :ap-req)))
	  ;; check the contents of the authenticator against the ticket....
	  ;; FIXME: for now we just assume it's ok
	  
	  ;; fixup the ap-req and return that
	  (setf (ap-req-ticket ap-req) ticket
		(ap-req-authenticator ap-req) (unpack #'decode-authenticator a))
	  
	  ap-req)))))

(defun ap-req-session-key (req)
  "Extract the session key from the AP request, so that clients may use it to wrap/unwrap messages."
  (declare (type ap-req req))
  (enc-ticket-part-key (ticket-enc-part (ap-req-ticket req))))

;; --------------------------------------------------------------

;; I just decrypted a ticket encryped with the rc4-hmac ! 
;; (unpack #'decode-enc-ticket-part 
;;   (decrypt-data (ticket-enc-part (kdc-rep-ticket *myticket*)) 
;;  			(string-to-key :rc4-hmac "password" nil)
;;			:usage (key-usage :ticket)))
;; where *myticket* is a tgs-rep structure
;; 

(defun generate-keylist (username password &optional realm)
  "Generate keys for all the registered profiles."
  (let ((salt (format nil "~A~A" 
		      (string-upcase realm) username)))
    (mapcar (lambda (type)
	      (make-encryption-key :type type
				   :value (string-to-key type password salt)))
	    (list-all-profiles))))

;; the kdc might send an etype-info2 back which contains information we need to use when generating keys
;; e.g. with the aes-cts type encryption, it might send a s2kparams which indicates what the iteration-count should be 


;; ---------------------------------------
;; for initial conrtext creation (I.e. GSS)

(defun pack-initial-context-token (message)
  (pack #'encode-initial-context-token message))
	
(defun unpack-initial-context-token (buffer)
  (let ((res (unpack #'decode-initial-context-token buffer)))
    (ecase res
      (krb-error (krb-error res))
      (otherwise res))))

;; ----------------------------------------
;; for sending KRB-PRIV messages

;; for encrypting/decrypting user message data in KRB-PRIV structures
(defun wrap-message (key octets local-address)
  "Encrypt a message and sign with the current timestamp.

KEY ::= an encryption-key structure defining the key to use.
OCTETS ::= an octet array containing the plaintext to encrypt.
LOCAL-ADDRESS ::= a HOST-ADDRESS structure naming the local server that is sending the message.
"
  (declare (type encryption-key key)
	   (type (vector (unsigned-byte 8)) octets)
	   (type host-address local-address))
  (let ((data (pack #'encode-enc-krb-priv-part 
		    (make-enc-krb-priv-part :data octets
					    :timestamp (get-universal-time)
					    :saddr local-address))))
    (pack #'encode-krb-priv
	  (make-krb-priv :enc-part 
			 (encrypt-data (encryption-key-type key)
				       data
				       (encryption-key-value key)
				       :usage :krb-priv)))))

(defun unwrap-message (key octets)
  "Decrypt the message and validate the timestamp."
  (declare (type encryption-key key)
	   (type (vector (unsigned-byte 8)) octets))
  (let ((enc (krb-priv-enc-part (unpack #'decode-krb-priv octets))))
    ;; validate the key types match
    (unless (eq (encryption-key-type key) (encrypted-data-type enc))
      (error "Key type ~S doesn't match encrypted data type ~S"
	     (encryption-key-type key) (encrypted-data-type enc)))
    (let ((data (decrypt-data enc (encryption-key-value key)
			      :usage :krb-priv)))
      (let ((priv (unpack #'decode-enc-krb-priv-part data)))
	;; FIXME: validate the timestamp
	(enc-krb-priv-part-data priv)))))



