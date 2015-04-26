# cerberus
A Kerberos (version 5) implementation.

This is an implementation of the Kerberos v5 authentication protocol, entirely in Common Lisp. 

## 1. Introduction
Kerberos is the de facto standard method of authentication over a network, notably in Microsoft Windows envrionments.
If you want to write robust and secure networked services, you need a robust and secure authentication system: Kerberos is
most likely the thing you need.

The basic principal of Kerberos is there is a trusted central authority which stores credentials (essentially passwords)
for each principal (user account). This is knowns as the Key Distribution Centre (KDC). 
A client can prove its identity to a server by requesting a message from the KDC 
which is encrypted with the server's private key. Only the server (and the KDC) have the knowledge to decrypt this message.
The client forwards this message to the server, who decrypts it and examines the contents of the message. Inside it will be 
some proof (e.g. a recent timestamp) that the client is who they say they are. 

In its simplest form, the Kerberos protocol consists of the following sequence of exchanges:
* Client sends a message to authentication service component of the KDC requesting a ticket for the ticket-granting server (TGS)
* The AS responds with a message encrypted with the client's private key, only the client can decrypt this message.
* The client sends a request to the TGS for a ticket to the desired principal (application server).
* The client sends this ticket to the application server using whatever application protocol is required.
* The application server validates the ticket and approves access to the client.

The details get more complicated, but that is the general idea.

## 2. Aims
The first stage is for clients and application servers to mutually authenticate each other. This means:
* Clients need to be able to login to the authentication server (AS) and request a ticket-granting ticket (TGT) for 
the ticket-granting service (TGS).
* Clients need to be able to use their TGT to request tickets for any other principal they require.
* Application servers need to be able to authenticate tickets that are presented to them.

In the long term, it would be good to have a full key-distribution center (KDC) included. This is a much bigger task
because now you need to have some secure database of principals/keys etc. Accessing the database would probably
entail some form of LDAP access, which is a massive task in itself. This can wait until a later date.

## 3. Usage
The public API is not finalized yet, but at the moment you can do something like:

```
;; login to the AS and request a TGT
CL-USER> (defparameter *tgt* (cerberus:request-tgt "Administrator" "password" "REALM" :kdc-address "10.1.1.1"))
*TGT*
;; request credentials to talk to the user "Administrator"
CL-USER> (defparameter *creds* (cerberus:request-credentials *tgt* (cerberus:principal "Administrator")))
*CREDS*
;; pack an AP-REQ structure to be sent to the application server
CL-USER> (defparameter *buffer* (cerberus:pack-ap-req *creds*))
*BUFFER*
;; send the *BUFFER* to the application server using whatever protocol you need

;; the application server must first generate a list of keys for the various encryption profiles
CL-USER> (defparameter *keylist* (cerberus:generate-keylist "password" :username "Administrator" :realm "REALM"))
*KEYLIST*
;; the application server receives the packed AP-REQ and validates it 
CL-USER> (cerberus:valid-ticket-p *keylist* (cerberus:pack-ap-req *creds*))
T

```

## 4. Encryption profiles
Cerberus supports a set of encryption "profiles", which are implemented by specializing a set of generic functions.
Currently, it has support for the following: DES-CBC-MD5, DES-CBC-MD4, DES-CBC-CRC, DES3-CBC-SHA1-KD, RC4-HMAC, RC4-HMAC-EXP, AES128-CTS-HMAC-SHA1-KD, AES256-CTS-HMAC-SHA1-KD. 

* The simple DES-based profiles are all implemented and appear to be working, DES-CBC-MD5, DES-CBC-MD4 and DES-CBC-CRC.
* The Microsoft profiles, RC4-HMAC and RC4-HMAC-EXP appear to be working correctly. 
* The DES3-CBC-SHA1-KD is implemented, looks like it's working. 
* The AES128 and AES256 profiles are working correctly.

## 5. Keytab files
You can load keytab files (as output from other Kerberos implementations, such from ktpass utility) using 
```
CL-USER> (cerberus:load-keytab "my.keytab")
```

## 6. TODO
* Need to be able to renew tickets.
* Somehow need to be able to use this in an application that requires GSS support.
* Need to support encrypting application messages using the session key.

## 7. Notes
* Encryption functions provided by the ironclad package.
* The ASN.1 serializer is specific to this project and NOT a generalized ASN.1 (DER) serializer. It makes certain assumptions which are valid
in the context of Kerberos messages, but are not generally applicable. Perhaps it could form the basis of one in the future.
* This was developed and tested against the Windows KDC (i.e. active directory). It should work with other KDCs such as MIT and Heimdal, 
but I've not tried.
* Need to understand the MS-PAC structures, these contain authorization data that is likely to be very useful. 

## 8. License
Licensed under the terms of the MIT license.

Frank James 
April 2015.

