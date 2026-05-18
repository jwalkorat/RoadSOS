import os
from twilio.rest import Client

TWILIO_ACCOUNT_SID = "YOUR_TWILIO_ACCOUNT_SID"
TWILIO_AUTH_TOKEN = "YOUR_TWILIO_AUTH_TOKEN"
TWILIO_PHONE_NUMBER = "+17407910803"
TARGET_PHONE_NUMBER = "+917359129704"

client = Client(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN)

try:
    print("Initiating test call...")
    twiml_script = """
    <Response>
        <Say voice="Polly.Joanna" language="en-US">
            Hello! The Twilio Authentication is now working perfectly!
        </Say>
    </Response>
    """
    call = client.calls.create(
        twiml=twiml_script,
        to=TARGET_PHONE_NUMBER,
        from_=TWILIO_PHONE_NUMBER
    )
    print(f"SUCCESS! Call SID: {call.sid}")
except Exception as e:
    print(f"FAILED! Error: {e}")
