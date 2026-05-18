# RoadSOS 🚑

A hybrid, offline-resilient emergency response application built with Flutter and Python.

RoadSOS ensures that an emergency signal reaches authorities even in complete offline dead zones (no Wi-Fi, no mobile data) by leveraging an intelligent SMS bridge and Twilio AI Voice routing.

## 🌟 Features
- **Online Mode:** Instantly triggers an AI emergency voice call over the internet.
- **Offline Mode:** Uses a native Android background SMS bridge to secretly dispatch SOS payloads to a trusted device.
- **MacroDroid Integration:** The trusted device intercepts the SMS and forwards the payload to the cloud via Webhook.
- **Twilio AI Voice:** An automated text-to-speech agent calls the user (or emergency services) providing the exact GPS coordinates and emergency category.

## 🚀 Setup Instructions

### 1. Flutter App (Frontend)
1. Clone the repository.
2. Open the project in Android Studio or VS Code.
3. Run `flutter pub get` to install dependencies.
4. **IMPORTANT - SENSITIVE DATA SETUP:** 
   - Open `lib/gps/gps_home_page.dart`.
   - Go to **Line 287** and **Line 296**.
   - Replace the `+910000000000` placeholders with your teammate's actual Indian phone number.

### 2. Python Server (Backend)
1. Navigate to the `backend/` directory.
2. Install Python dependencies: `pip install -r requirements.txt`
3. **IMPORTANT - SENSITIVE DATA SETUP:**
   - Open `backend/server.py`.
   - Go to **Lines 11-13** and replace the placeholders with your actual Twilio Account SID, Auth Token, and Twilio Phone Number.
   - Go to **Line 16** and replace the `+910000000000` placeholder with your verified test phone number.
4. Start the server: `python server.py`
5. Expose the server using localtunnel: `lt --port 5000 --subdomain roadsos-final-demo`

### 3. MacroDroid Bridge (Teammate's Phone)
1. Install MacroDroid.
2. **Trigger:** SMS Received from Any Number containing `SOS|`
3. **Action:** HTTP Request (POST) to `https://sour-rockets-smoke.loca.lt/incoming-sms`
4. **Header:** `Bypass-Tunnel-Reminder: true`
5. **Body (x-www-form-urlencoded):** `Body=[sms_message]` and `From=[sms_number]`
