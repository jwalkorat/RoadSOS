import logging
import os
import requests as req
import groq
from flask import Flask, request, jsonify
from twilio.rest import Client
from twilio.twiml.voice_response import VoiceResponse, Gather
from twilio.twiml.messaging_response import MessagingResponse

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass


# ─────────────────────────────────────────────────────────────────
# CONFIG — Loaded dynamically from environment variables
# ─────────────────────────────────────────────────────────────────
TWILIO_ACCOUNT_SID  = os.getenv("TWILIO_ACCOUNT_SID", "AC00000000000000000000000000000000")
TWILIO_AUTH_TOKEN   = os.getenv("TWILIO_AUTH_TOKEN", "00000000000000000000000000000000")
TWILIO_PHONE_NUMBER = os.getenv("TWILIO_PHONE_NUMBER", "+17623713288")
TARGET_PHONE_NUMBER = os.getenv("TARGET_PHONE_NUMBER", "+917359129704")

# Add as many Groq keys here as you want to bypass the 30 RPM limit, comma-separated
groq_keys_raw = os.getenv("GROQ_API_KEYS", "")
if groq_keys_raw:
    GROQ_API_KEYS = [k.strip() for k in groq_keys_raw.split(",") if k.strip()]
else:
    GROQ_API_KEYS = ["YOUR_GROQ_API_KEY"]

groq_key_index = 0

def get_next_groq_key():
    global groq_key_index
    if not GROQ_API_KEYS:
        return "YOUR_GROQ_API_KEY"
    key = GROQ_API_KEYS[groq_key_index]
    has_actual_keys = any("YOUR_" not in k for k in GROQ_API_KEYS)
    while "YOUR_" in key and has_actual_keys:
        groq_key_index = (groq_key_index + 1) % len(GROQ_API_KEYS)
        key = GROQ_API_KEYS[groq_key_index]
    
    groq_key_index = (groq_key_index + 1) % len(GROQ_API_KEYS)
    return key

# Dynamic URLs will be used instead of hardcoded PUBLIC_URL

# ─────────────────────────────────────────────────────────────────
# INIT
# ─────────────────────────────────────────────────────────────────
app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s: %(message)s")

twilio_client = Client(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN)
# Gemini model is now instantiated dynamically per request with rotated keys

# In-memory session store: CallSid -> session data
call_sessions = {}

# ─────────────────────────────────────────────────────────────────
# LANGUAGE MAP  (country code → Twilio language + Polly voice)
# ─────────────────────────────────────────────────────────────────
COUNTRY_LANG = {
    "IN": ("hi-IN",  "Aditi"),      # India — Hindi
    "US": ("en-US",  "Joanna"),     # USA — English
    "GB": ("en-GB",  "Amy"),        # UK  — English
    "FR": ("fr-FR",  "Celine"),     # France — French
    "DE": ("de-DE",  "Marlene"),    # Germany — German
    "JP": ("ja-JP",  "Mizuki"),     # Japan — Japanese
    "CN": ("cmn-CN", "Zhiyu"),      # China — Mandarin
    "ES": ("es-ES",  "Conchita"),   # Spain — Spanish
    "BR": ("pt-BR",  "Vitoria"),    # Brazil — Portuguese
    "AE": ("ar-XA",  "Zeina"),      # UAE — Arabic
}
DEFAULT_LANG  = ("en-US", "Joanna")

# ─────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────
def reverse_geocode(lat, lng):
    """Convert lat/lng → human-readable address + country code."""
    try:
        url = (f"https://nominatim.openstreetmap.org/reverse"
               f"?lat={lat}&lon={lng}&format=json&zoom=18&addressdetails=1")
        resp = req.get(url, headers={"User-Agent": "RoadSOS/1.0 Emergency App"}, timeout=4)
        if resp.status_code == 200:
            data = resp.json()
            address      = data.get("display_name", f"{lat}, {lng}")
            country_code = data.get("address", {}).get("country_code", "").upper()
            return address, country_code
    except Exception as e:
        logging.warning(f"Reverse geocode failed: {e}")
    return f"Latitude {lat}, Longitude {lng}", "US"


def get_lang(country_code):
    return COUNTRY_LANG.get(country_code, DEFAULT_LANG)


def build_system_prompt(category, address, lat, lng, country_code, lang_code):
    """Dynamic system prompt based on emergency type + location."""
    language_name = lang_code.split("-")[0].upper()

    if "police" in category.lower():
        persona = (
            "You are an AI emergency dispatch assistant calling police on behalf of a citizen in danger. "
            "Speak ONLY to law enforcement. Prioritize: exact address, that the victim cannot speak, "
            "and that the threat may still be active. Assume armed if asked."
        )
    elif "ambul" in category.lower():
        persona = (
            "You are an AI emergency dispatch assistant calling an ambulance service on behalf of a patient. "
            "Prioritize: exact address, that this was a silent SOS panic button, "
            "and that exact symptoms are unknown but the situation is life-threatening."
        )
    else:
        persona = (
            "You are an AI emergency dispatch assistant calling medical trauma services on behalf of a patient. "
            "Prioritize: exact address, that the victim triggered a silent SOS panic button, "
            "request immediate ambulance dispatch."
        )

    return f"""
{persona}

CRITICAL RULES — follow them exactly:
1. You must respond ONLY with a valid JSON object. No markdown, no pre-text.
2. The default language is '{lang_code}'. However, if the operator speaks to you in a different language, YOU MUST switch and reply natively in their language.
3. DO NOT output asterisks (*), markdown, or ellipses (...). The voice engine will read them out loud as "dot dot dot". Use plain conversational text and commas only.
4. The victim's location is: {address}
5. The exact GPS coordinates are {lat}, {lng}. If asked for exact GPS, you MUST translate the words "Latitude" and "Longitude" into the caller's language and read the numbers clearly.
6. If asked for symptoms/condition: say it was a silent panic button, exact condition unknown, treat as critical.
7. If asked for name/identity: say the identity is unknown, it was triggered by an automated SOS application.
8. Never say you are an AI unless directly asked. Just dispatch facts.

JSON FORMAT REQUIRED:
{{
    "language_code": "<Twilio language code of your reply, e.g., 'gu-IN' for Gujarati, 'hi-IN' for Hindi, 'fr-FR' for French>",
    "reply": "<Your 2-sentence conversational reply in that language>",
    "call_status": "<'keep_call_active' or 'hang_up_call'. Output 'hang_up_call' ONLY if the emergency is resolved AND the operator no longer needs you, OR if they explicitly ask to cut the call. IF THE OPERATOR ASKS YOU NOT TO CUT THE CALL, YOU MUST OUTPUT 'keep_call_active' NO MATTER WHAT.>"
}}
""".strip()

def ask_gemini(system_prompt, conversation_history, user_message):
    """Send conversation to Groq and get a super-fast response with key rotation."""
    messages = [{"role": "system", "content": system_prompt}]
    for m in conversation_history:
        messages.append({"role": "user", "content": m["operator"]})
        messages.append({"role": "assistant", "content": m["agent"]})
    messages.append({"role": "user", "content": user_message})

    total_keys = len(GROQ_API_KEYS)
    for attempt in range(total_keys):
        next_key = get_next_groq_key()
        logging.info(f"🔑 Trying Groq key={next_key[:8]}...")
        try:
            # max_retries=0 prevents the SDK from sleeping for 19s on rate limits, which causes Twilio to timeout.
            client = groq.Groq(api_key=next_key, max_retries=0)
            response = client.chat.completions.create(
                model="llama-3.3-70b-versatile",
                messages=messages,
                response_format={"type": "json_object"},
                max_tokens=500,
                temperature=0.5
            )
            logging.info("✅ Success with Groq!")
            return response.choices[0].message.content.strip()
        except Exception as e:
            err = str(e)
            if "429" in err or "rate limit" in err.lower() or "too many requests" in err.lower():
                logging.warning(f"⚠️  Groq key {next_key[:8]} rate-limited. Trying next key...")
                continue
            elif "401" in err or "invalid_api_key" in err.lower():
                logging.warning(f"⚠️  Groq key {next_key[:8]} is INVALID (401). Trying next key...")
                continue
            else:
                logging.error(f"Groq API error: {e}")
                break

    logging.error("❌ All Groq keys exhausted!")
    return "Please hold. Dispatching emergency services to the reported location immediately."


def build_twiml_gather(say_text, lang_code, action_url):
    """Build a TwiML response: Say something, then listen in the correct language."""
    response = VoiceResponse()
    gather = Gather(
        input="speech",
        action=action_url,
        method="POST",
        language=lang_code,
        speech_timeout="auto",
        actionOnEmptyResult="true",
        hints="location, address, ambulance, police, injury, bleeding, help, emergency, trauma"
    )
    
    # Map explicit Google Cloud voices for languages that Twilio Basic/Polly don't support natively
    voice = None
    if "gu-IN" in lang_code: voice = "Google.gu-IN-Standard-A"
    elif "mr-IN" in lang_code: voice = "Google.mr-IN-Standard-A"
    elif "ta-IN" in lang_code: voice = "Google.ta-IN-Standard-A"
    elif "te-IN" in lang_code: voice = "Google.te-IN-Standard-A"
    elif "bn-IN" in lang_code: voice = "Google.bn-IN-Standard-A"
    elif "hi-IN" in lang_code: voice = "Polly.Aditi"
    elif "en-IN" in lang_code: voice = "Polly.Aditi"

    if voice:
        gather.say(say_text, voice=voice, language=lang_code)
        response.append(gather)
        response.say("No response received. Keeping line open. Please speak now.", voice=voice, language=lang_code)
    else:
        # Fallback to Twilio auto-select for generic global languages (like ur-PK, fr-FR)
        gather.say(say_text, language=lang_code)
        response.append(gather)
        response.say("No response received. Keeping line open. Please speak now.", language=lang_code)
    
    return str(response)


# ─────────────────────────────────────────────────────────────────
# ROUTE 1: Flutter app triggers SOS (online mode)
# ─────────────────────────────────────────────────────────────────
@app.route('/trigger-call', methods=['POST'])
def trigger_call():
    try:
        data     = request.json or {}
        lat      = data.get('lat', 0)
        lng      = data.get('lng', 0)
        category = data.get('category', 'Medical Emergency')

        logging.info(f"🚨 SOS received! lat={lat}, lng={lng}, category={category}")

        # Step 1: Reverse geocode to get human address + country
        address, country_code = reverse_geocode(lat, lng)
        lang_code = get_lang(country_code)[0]

        logging.info(f"📍 Address: {address} | Country: {country_code} | Lang: {lang_code}")

        # Step 2: Build the system prompt for this session
        system_prompt = build_system_prompt(category, address, lat, lng, country_code, lang_code)

        # Step 3: Opening statement (fast — no AI needed for first line)
        opening = (
            f"Emergency Alert. This is an automated AI assistant calling on behalf of a citizen in critical danger. "
            f"The victim is at {address}. Please ask me for information you need to dispatch help."
        )

        # Step 4: Initiate Twilio call — pass context via URL params
        import urllib.parse
        encoded_category = urllib.parse.quote(category)
        encoded_address  = urllib.parse.quote(address)

        tunnel_base = request.host_url.rstrip('/')

        call = twilio_client.calls.create(
            to=TARGET_PHONE_NUMBER,
            from_=TWILIO_PHONE_NUMBER,
            twiml=build_twiml_gather(
                opening,
                lang_code,
                f"{tunnel_base}/ai-response?category={encoded_category}&address={encoded_address}&lat={lat}&lng={lng}&lang={lang_code}"
            )
        )

        logging.info(f"📞 Call initiated! SID: {call.sid}")

        # Step 5: Send Google Maps SMS simultaneously
        maps_link = f"https://maps.google.com/?q={lat},{lng}"
        twilio_client.messages.create(
            body=f"🚨 RoadSOS ALERT\nLocation: {address}\nGoogle Maps: {maps_link}\nCategory: {category}",
            to=TARGET_PHONE_NUMBER,
            from_=TWILIO_PHONE_NUMBER
        )
        logging.info("📱 SMS with Maps link sent!")

        return jsonify({"success": True, "call_sid": call.sid, "address": address})

    except Exception as e:
        logging.error(f"Error in trigger_call: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


# ─────────────────────────────────────────────────────────────────
# ROUTE 2: AI responds to operator's spoken question
# ─────────────────────────────────────────────────────────────────
@app.route('/ai-response', methods=['POST'])
def ai_response():
    try:
        call_sid      = request.values.get('CallSid', '')
        speech_result = request.values.get('SpeechResult', '').strip()
        category      = request.args.get('category', 'Medical Emergency')
        address       = request.args.get('address', 'Unknown location')
        lat           = request.args.get('lat', 'unknown')
        lng           = request.args.get('lng', 'unknown')
        lang_code     = request.args.get('lang', 'en-US')
        voice         = get_lang("IN")[1] if "IN" in lang_code else "Polly.Joanna"

        logging.info(f"🎤 Operator said: '{speech_result}' | CallSid: {call_sid}")

        # Get or create session
        if call_sid not in call_sessions:
            call_sessions[call_sid] = {
                "history": [],
                "system_prompt": build_system_prompt(category, address, lat, lng, "XX", lang_code),
                "empty_count": 0,
                "latest_address": address,
                "latest_lat": lat,
                "latest_lng": lng
            }

        session       = call_sessions[call_sid]
        system_prompt = session["system_prompt"]
        history       = session["history"]

        # Check for silence/timeout
        if not speech_result:
            session["empty_count"] = session.get("empty_count", 0) + 1
            if session["empty_count"] >= 2:
                logging.info(f"📴 Hanging up due to repeated silence. CallSid: {call_sid}")
                resp = VoiceResponse()
                resp.say("No response detected. Terminating emergency call. Help has been requested.", language=lang_code)
                resp.hangup()
                return str(resp), 200, {'Content-Type': 'text/xml'}
            
            speech_result = "Can you repeat the location or confirm help is on the way?"
        else:
            session["empty_count"] = 0  # reset on active speech

        # Get AI response (JSON)
        json_response_text = ask_gemini(system_prompt, history, speech_result)
        
        try:
            import json
            data = json.loads(json_response_text)
            ai_reply = data.get("reply", "Dispatching help now.")
            new_lang_code = data.get("language_code", lang_code)
            call_status = data.get("call_status", "keep_call_active")
            logging.info(f"🤖 AI dynamically switched language to: {new_lang_code}")
        except Exception as e:
            logging.error(f"Failed to parse AI JSON: {e}")
            ai_reply = json_response_text.strip()
            new_lang_code = lang_code
            call_status = "keep_call_active"

        logging.info(f"🤖 AI reply: '{ai_reply}'")

        # Save to history
        history.append({"operator": speech_result, "agent": ai_reply})

        # Save session to file for persistent debugging
        import os
        os.makedirs("logs", exist_ok=True)
        with open(f"logs/session_{call_sid}.json", "w", encoding="utf-8") as f:
            json.dump(history, f, indent=4, ensure_ascii=False)

        # Build tunnel base from request
        tunnel_base  = request.host_url.rstrip('/')
        
        # If call_status is hang_up_call, hang up!
        if call_status == "hang_up_call":
            logging.info(f"📴 AI decided to hang up. CallSid: {call_sid}")
            
            # Map explicit Google Cloud voices for languages that Twilio Basic/Polly don't support natively
            voice = None
            if "gu-IN" in new_lang_code: voice = "Google.gu-IN-Standard-A"
            elif "mr-IN" in new_lang_code: voice = "Google.mr-IN-Standard-A"
            elif "ta-IN" in new_lang_code: voice = "Google.ta-IN-Standard-A"
            elif "te-IN" in new_lang_code: voice = "Google.te-IN-Standard-A"
            elif "bn-IN" in new_lang_code: voice = "Google.bn-IN-Standard-A"
            elif "hi-IN" in new_lang_code: voice = "Polly.Aditi"
            elif "en-IN" in new_lang_code: voice = "Polly.Aditi"

            import urllib.parse
            encoded_cat  = urllib.parse.quote(category)
            encoded_addr = urllib.parse.quote(address)
            action_url   = f"{tunnel_base}/ai-response?category={encoded_cat}&address={encoded_addr}&lat={lat}&lng={lng}&lang={new_lang_code}"

            resp = VoiceResponse()
            
            # Put the final message in a Gather so the user can barge in and say "don't cut"
            gather = Gather(
                input="speech",
                action=action_url,
                method="POST",
                language=new_lang_code,
                speech_timeout="auto",
                timeout=3, # Wait 3 seconds after speaking before hanging up
                actionOnEmptyResult="false" # If no speech, fall through to Hangup
            )
            
            if voice:
                gather.say(ai_reply, voice=voice, language=new_lang_code)
            else:
                gather.say(ai_reply, language=new_lang_code)
                
            resp.append(gather)
            resp.hangup()
            return str(resp), 200, {'Content-Type': 'text/xml'}

        import urllib.parse
        encoded_cat  = urllib.parse.quote(category)
        encoded_addr = urllib.parse.quote(address)
        
        # Pass the NEW lang_code in the action URL so the next Twilio <Gather> listens in the new language!
        action_url   = f"{tunnel_base}/ai-response?category={encoded_cat}&address={encoded_addr}&lat={lat}&lng={lng}&lang={new_lang_code}"

        twiml = build_twiml_gather(ai_reply, new_lang_code, action_url)
        return twiml, 200, {'Content-Type': 'text/xml'}

    except Exception as e:
        logging.error(f"Error in ai_response: {e}")
        resp = VoiceResponse()
        resp.say("System error. Please dispatch emergency services to the last known location.")
        return str(resp), 200, {'Content-Type': 'text/xml'}


# ─────────────────────────────────────────────────────────────────
# ROUTE 3: Incoming SMS (offline fallback via MacroDroid)
# ─────────────────────────────────────────────────────────────────
@app.route('/incoming-sms', methods=['POST'])
def incoming_sms():
    try:
        body        = request.values.get('Body', '').strip()
        from_number = request.values.get('From', 'Unknown')
        logging.info(f"📩 SMS from {from_number}: {body}")

        parts = body.split('|')
        if len(parts) >= 4 and parts[0].upper() == 'SOS':
            lat      = parts[1]
            lng      = parts[2]
            category = parts[3]

            address, country_code = reverse_geocode(lat, lng)
            lang_code, _ = get_lang(country_code)

            logging.info(f"📍 Offline SOS! Address: {address}")

            opening = (
                f"Emergency Alert. This is an automated AI assistant. "
                f"An offline SOS was triggered. The victim is at {address}. "
                f"Please ask me for the information you need."
            )

            tunnel_base = request.host_url.rstrip('/')
            import urllib.parse
            encoded_cat  = urllib.parse.quote(category)
            encoded_addr = urllib.parse.quote(address)

            call = twilio_client.calls.create(
                to=TARGET_PHONE_NUMBER,
                from_=TWILIO_PHONE_NUMBER,
                twiml=build_twiml_gather(
                    opening,
                    lang_code,
                    f"{tunnel_base}/ai-response?category={encoded_cat}&address={encoded_addr}&lat={lat}&lng={lng}&lang={lang_code}"
                )
            )
            logging.info(f"📞 Offline SOS Call initiated! SID: {call.sid}")

            maps_link = f"https://maps.google.com/?q={lat},{lng}"
            twilio_client.messages.create(
                body=f"🚨 RoadSOS OFFLINE ALERT\nLocation: {address}\nGoogle Maps: {maps_link}\nCategory: {category}",
                to=TARGET_PHONE_NUMBER,
                from_=TWILIO_PHONE_NUMBER
            )

        resp = MessagingResponse()
        resp.message("SOS Received. Help is being dispatched.")
        return str(resp)

    except Exception as e:
        logging.error(f"Error in incoming_sms: {e}")
        return "Error", 500


# ─────────────────────────────────────────────────────────────────
# ROUTE 4: Live Location Updates from Flutter App
# ─────────────────────────────────────────────────────────────────
@app.route('/update-location', methods=['POST'])
def update_location():
    try:
        data = request.json or {}
        call_sid = data.get('call_sid')
        lat = data.get('lat')
        lng = data.get('lng')

        if call_sid and call_sid in call_sessions and lat and lng:
            address, _ = reverse_geocode(lat, lng)
            session = call_sessions[call_sid]
            
            # If address changed, inject a system note so AI knows
            if session.get("latest_address") != address or session.get("latest_lat") != lat:
                session["latest_address"] = address
                session["latest_lat"] = lat
                session["latest_lng"] = lng
                session["history"].append({
                    "operator": "[SYSTEM NOTE: DO NOT REPLY TO THIS]", 
                    "agent": f"The victim's location has updated to Address: {address}. GPS: Lat {lat}, Lng {lng}. Use this if asked."
                })
                logging.info(f"📍 Updated session location for {call_sid} to {address}")
            return jsonify({"success": True, "address": address})
        return jsonify({"success": False, "error": "Invalid session or missing data"}), 400
    except Exception as e:
        logging.error(f"Error in update_location: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

@app.route('/debug-sessions', methods=['GET'])
def debug_sessions():
    return jsonify(call_sessions)


if __name__ == '__main__':
    print("Starting RoadSOS AI Agent Backend...")
    print("Endpoints: /trigger-call  /ai-response  /incoming-sms  /update-location  /debug-sessions")
    app.run(host='0.0.0.0', port=5000, debug=True)
