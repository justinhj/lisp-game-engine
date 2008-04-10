; An SDL audio mixer

(declaim (optimize (debug 2) (safety 2) (speed 1)))

(defstruct playback-status
  initialised
  audio-buffer
  paused
  samples
  sounds
  audio-spec
  driver-name)

(defstruct sample
  filename
  audio-spec
  data
  len)

(defstruct sound
  sample
  pos
  loop)


(defparameter *audio-buffer-size* 4096)

(defparameter *playback-status* (make-playback-status))

; From On Lisp
(defmacro while (test &body body)
  `(do ()
       ((not ,test))
     ,@body))

; This is a simple version of memcpy(dst, src, num)
; it takes two pointers and copies num bytes from 1 to the other
; there's no bounds checking, this is only for use when you know
; exactly what you're copying
(defun my-memcpy(dst src num)
  (loop for b from 0 to (1- num) do 
       (setf (cffi:mem-aref dst :unsigned-char b) (cffi:mem-aref src :unsigned-char b))))

; Define callback function for managing the audio buffer
; void SDLCALL mixer-callback(void *unused, Uint8 *stream, int len)
(cffi:defcallback mixer-callback :void ((unused :pointer) (stream :pointer) (len :int))

  (return-from mixer-callback)

  (let ((sound (first (slot-value *playback-status* 'sounds))))
    (if (null sound)
	(return-from mixer-callback))

    (let* ((sample (slot-value sound 'sample))
	  (waveptr (cffi:inc-pointer 
		    (slot-value sample 'data)
		    (slot-value sample 'pos))) ; pointer into sound data at play pos
	  (waveleft (- (slot-value sample 'len)
		       (slot-value sample 'pos)))) ; how much sound left

      (while (<= waveleft len) ; while enough sound to fill len bytes of the audio stream buffer
	
        ; send all the audio data you can
	(sdl-cffi::SDL-Mix-Audio stream waveptr waveleft sdl-cffi::SDL-MIX-MAXVOLUME)

         ; increment the stream pointer by what you wrote
	(cffi:incf-pointer stream waveleft)
	(decf len waveleft) ; reduce the amount of data we still need to write

        ; reset the sound pointer to point at the beginning
	(setf waveptr (slot-value sample 'data)) 
	(setf waveleft (slot-value sample 'len))
	(setf (slot-value sample 'pos) 0))

      ; at this point we have more than enough sound, so just copy len bytes of it
      ; and increment the playing sounds position by len
      (sdl-cffi::SDL-Mix-Audio stream waveptr len sdl-cffi::SDL-MIX-MAXVOLUME)
      (incf (slot-value sample 'pos) len))))

; allocate a SDL_AudioSpec with the specified parameters

(defun allocate-sdl-audiospec(des-freq des-format des-samples des-callback des-userdata des-channels)
  (let ((spec (cffi:foreign-alloc 'sdl-cffi::SDL-Audio-Spec)))
    (cffi:with-foreign-slots ((sdl-cffi::freq 
			       sdl-cffi::format 
			       sdl-cffi::samples 
			       sdl-cffi::callback 
			       sdl-cffi::channels 
			       sdl-cffi::userdata) 
			      spec sdl-cffi::SDL-Audio-Spec)
      (setf sdl-cffi::freq des-freq)
      (setf sdl-cffi::format des-format)
      (setf sdl-cffi::samples des-samples)
      (setf sdl-cffi::callback des-callback)
      (setf sdl-cffi::channels des-channels)
      (setf sdl-cffi::userdata des-userdata))
    spec))

(defun debug-print-audio-spec(spec)
  "display information about the provided sdl-audio-spec"
  (cffi:with-foreign-slots ((sdl-cffi::freq 
			     sdl-cffi::format 
			     sdl-cffi::channels
			     sdl-cffi::callback
			     sdl-cffi::userdata)
			    spec
			    sdl-cffi::SDL-Audio-Spec)
    (format t "audio spec: freq ~a format ~x channels ~a callback ~a userdata ~a~%"
	    sdl-cffi::freq 
	    sdl-cffi::format 
	    sdl-cffi::channels
	    sdl-cffi::callback
	    sdl-cffi::userdata)))

(defun load-and-convert-sample(filename dest-spec)
  "loads the wav file, converts it to the dest-spec"

  ; todo create the format converter, run it and free the original data

  (let* ((sample (make-sample :filename filename
			      :audio-spec (cffi:foreign-alloc 'sdl-cffi::SDL-Audio-Spec)
			      :data (cffi:foreign-alloc :pointer)
			      :len (cffi:foreign-alloc :unsigned-int)))
	 (loaded-wav-spec 
	  (with-slots (filename audio-spec data len) sample
	    (sdl-cffi::sdl-load-wav filename audio-spec data len))))

    ; load-wav file returns a null pointer if it does not succeed. in which 
    ; case the function will return nil
    (if (cffi:null-pointer-p loaded-wav-spec)
	(return-from load-and-convert-sample nil))

    ; the sample len is a pointer to an unsigned-int, lets just make it the actual value
    (setf (slot-value sample 'len) (cffi:mem-ref (slot-value sample 'len) :unsigned-int))

    ; build the audio converter

    (let* ((audio-converter (cffi:foreign-alloc 'sdl-cffi::SDL-Audio-CVT))
	   (build-converter-result 
	    (sdl-cffi::SDL-Build-Audio-CVT audio-converter 
		     ; source format params			   
		     (cffi:foreign-slot-value loaded-wav-spec 'sdl-cffi::sdl-audio-spec 'sdl-cffi::format)
		     (cffi:foreign-slot-value loaded-wav-spec 'sdl-cffi::sdl-audio-spec 'sdl-cffi::channels)
		     (cffi:foreign-slot-value loaded-wav-spec 'sdl-cffi::sdl-audio-spec 'sdl-cffi::freq)
		     ; dest format params
		     (cffi:foreign-slot-value dest-spec 'sdl-cffi::sdl-audio-spec 'sdl-cffi::format)
		     (cffi:foreign-slot-value dest-spec 'sdl-cffi::sdl-audio-spec 'sdl-cffi::channels)
		     (cffi:foreign-slot-value dest-spec 'sdl-cffi::sdl-audio-spec 'sdl-cffi::freq))))

      (if (< build-converter-result 0)
	  (progn
;	    (sdl-cffi::sdl-free-wav (slot-value sample 'data))  ; todo must free this ...
	    (cffi:foreign-free audio-converter)
	    (return-from load-and-convert-sample nil)))

      ; sample now loaded, convert built, we need to do the conversion

      ; allocate and assign a buffer for the conversion
      ; wav_cvt.buf = malloc(wav_len * wav_cvt.len_mult) 	    
      (let* ((buffer-size (* (slot-value sample 'len)
			     (cffi:foreign-slot-value audio-converter 
						      'sdl-cffi::SDL-Audio-CVT 'sdl-cffi::len-mult)))
	     (sample-buffer
	      (cffi:foreign-alloc :unsigned-char
				  :count buffer-size)))

	(format t "buffer ~a buffer size ~a original ~a~%" sample-buffer buffer-size (slot-value sample 'len))
	
	(setf (cffi:foreign-slot-value audio-converter 'sdl-cffi::SDL-Audio-CVT 'sdl-cffi::buf) sample-buffer)

        ; wav_cvt.len = wav_len;
	      
	(setf (cffi:foreign-slot-value audio-converter 'sdl-cffi::SDL-Audio-CVT 'sdl-cffi::len) (slot-value sample 'len))

        ; memcpy(wav_cvt.buf, wav_buf, wav_len);

	; copy the source sample to the new buffer
	(my-memcpy sample-buffer
		   (slot-value sample 'data)
		   (slot-value sample 'len))

	(let ((sample-length 0)
	      (convert-result 
	       (sdl-cffi::SDL-Convert-Audio audio-converter)))

	  (setf sample-length (coerce (round 
				       (* (cffi:foreign-slot-value audio-converter 
								   'sdl-cffi::SDL-Audio-CVT 'sdl-cffi::len)
					  (cffi:foreign-slot-value audio-converter 
								   'sdl-cffi::SDL-Audio-CVT 'sdl-cffi::len-ratio)))
				      'fixnum))
	  
	  (format t "new sample length ~a~%" sample-length)
		
	  ; free the old sample data

; 	  (cffi:foreign-free (slot-value sample 'data)) ; todo must free this (but is it double free?)

   	  ; set the wave structure to represent the new sample

	  (setf (slot-value sample 'audio-spec) dest-spec)
 	  (setf (slot-value sample 'data) sample-buffer)
	  (setf (slot-value sample 'len) sample-length)

	  sample)))))

(defun free-sample(sample)
  "free up the sample data"
  (format t "sample ~a memory free ~a" (slot-value sample 'filename) (slot-value sample 'data)))
;  (sdl-cffi::sdl-free-wav (slot-value sample 'data))) ; todo need to export free-wav todo must free

(defun allocate-desired-audiospec()
  "setup an audio spec as specified"
  (allocate-sdl-audiospec 44100 sdl-cffi::AUDIO-S16LSB *audio-buffer-size* (cffi:get-callback 'mixer-callback) 
			  (cffi:null-pointer) 2))

(defun init-audio()
  "open audio device"
  (let ((desired-audio-spec (allocate-desired-audiospec))
	(obtained-audio-spec (cffi:foreign-alloc 'sdl-cffi::SDL-Audio-Spec)))
      
    ; set the mixer callback 
     (setf (cffi:foreign-slot-value desired-audio-spec
 				   'sdl-cffi::sdl-audio-spec 'sdl-cffi::callback)
 	  (cffi:get-callback 'mixer-callback))
    
     (let ((open-audio-result
	    (sdl-cffi::SDL-Open-Audio desired-audio-spec obtained-audio-spec))
	   (rstring
	    (cffi:foreign-alloc :unsigned-char :count 128)))
      
       (if (< open-audio-result 0)
	   (error "Open audio failed: ~a~%" (sdl-cffi::sdl-get-error)))

       ; save the driver name
       (setf (slot-value *playback-status* 'driver-name) 
	     (sdl-cffi::SDL-Audio-Driver-Name rstring 128))

       (format t "Driver name: ~a~%" (slot-value *playback-status* 'driver-name)))))
;)))
;;;       ; a buffer to do the sound mixing in 
;;;       (setf (slot-value *playback-status* 'audio-buffer) (cffi:foreign-alloc :unsigned-char :count *audio-buffer-size*))

;;;       (setf (slot-value *playback-status* 'audio-spec) obtained-audio-spec)
      
;;;       (setf (slot-value *playback-status* 'initialised) t))))

(defun quit-audio()
  "Free up any sample data and clear the sample list, and close the SDL audio system down"

  (mapcar #'free-sample (slot-value *playback-status* 'samples))
  (setf (slot-value *playback-status* 'samples) nil)

  (sdl-cffi::SDL-Close-Audio)
  (setf (slot-value *playback-status* 'initialised) nil))

(defun load-sample(filename)
  "load a sample file, convert it to the current audio spec, and add it to the sample list"

  (if (slot-value *playback-status* 'initialised)
      (push 
       (load-and-convert-sample filename (slot-value *playback-status* 'audio-spec))
       (slot-value *playback-status* 'samples))
      (error "you must call init-audio before loading samples")))

(defun play-sound(sample &optional (looping nil))
  (let ((sound (make-sound :sample sample :pos 0 :loop looping)))
    (push sound (slot-value *playback-status* 'sounds))))

(defun testms()
; (multisounds "/home/justinhj/sounds/trance_02_05.WAV" "/home/justinhj/sounds/trance_06_04.WAV"))
  (multisounds "/home/justinhj/sounds/test.wav" "/home/justinhj/sounds/test.wav"))

(defun multisounds(sample1 sample2)
  (sdl:with-init (sdl:sdl-init-video sdl:sdl-init-audio)

    (sdl:window 200 200)
    (setf (sdl:frame-rate) 60)

;    (sdl::set-sdl-quit-on-exit t) 

    ; lispworks - need this to enable callbacks from foreign code into lisp
    #+lispworks (sys:setup-for-alien-threads)

    (init-audio)

 ;   (format t "Opened audio. Driver : \"~a\"~%" (slot-value *playback-status* 'driver-name))
 ;   (debug-print-audio-spec (slot-value *playback-status* 'audio-spec))

    ; open the example samples 

;    (load-sample sample1)
;    (load-sample sample2)

;    (play-sound (first (slot-value *playback-status* 'samples)) t)

 ;   (sdl-cffi::SDL-Pause-Audio 0) ; unpause the audio

    (sdl:with-events ()
      (:key-down-event (:key key)
		       (if (sdl:key= key :SDL-KEY-ESCAPE)
			   (sdl:push-quit-event)))
      (:quit-event () t)
      (:idle ()
	     (sdl:draw-pixel-* (random 200) (random 200)
			       :color (sdl:color :r (+ 200 (random 44))
						 :g 0
						 :b 0)
			       :surface sdl:*default-display*)
	     (sdl:update-display)))
  ))  
 ;   (quit-audio)))






