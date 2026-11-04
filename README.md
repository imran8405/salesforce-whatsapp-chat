# 📱 Salesforce WhatsApp Cloud API – Two-Way Chat Integration

**Full LWC Chat UI + Outbound Messaging + Inbound Webhooks + Media Attachments + Real-Time Refresh + Message Status Tracking**

This project implements a WhatsApp-style messaging system inside Salesforce using the Meta WhatsApp Cloud API. It includes:

✔️ Full chat UI built in LWC
✔️ Outbound WhatsApp messages (Text, Template, Media)
✔️ Send photos, videos, audio and documents from Salesforce
✔️ Receive photos, videos, audio, documents and stickers (saved as Salesforce Files)
✔️ Retry for failed incoming file downloads
✔️ Real-time inbound messages via Webhook
✔️ Webhook verification + signature check (X-Hub-Signature-256)
✔️ Sent / Delivered / Read message status tracking
✔️ Auto-refresh chat (1-sec polling)
✔️ Delete chat functionality
✔️ Contact-specific threaded messaging
✔️ Emoji picker
✔️ Typing indicator
✔️ Notification ping sound
✔️ Clean mobile-like WhatsApp UX
✔️ Apex services for all backend logic

---

## 🚀 Features

### 1. Real WhatsApp-Style Chat UI (LWC)

- Smooth UI with WhatsApp-like colors
- Inbound (left) + Outbound (right) bubbles
- Sent ✓, Delivered ✓✓, Read ✓✓ (blue)
- Auto-scroll to bottom
- Typing indicator
- Emoji picker
- Notification sound for new messages
- New-message button with unread count
- Inline image, video and audio players; download link for documents
- 3-dot header menu with **Send hello_world template** and **Delete Chat**

### 2. Outbound Messaging (Apex → WhatsApp API)

Send WhatsApp messages via:

```apex
WhatsAppOutboundService.sendText(contactId, text)
WhatsAppOutboundService.sendTemplate(contactId, templateName, languageCode)
WhatsAppMediaService.sendMedia(contactId, contentVersionId, caption)
```

Logs are stored in `WhatsApp_Message__c` with fields:

- Message
- Time
- Status
- Direction (Inbound/Outbound)
- WhatsApp Message ID
- Phone
- Message Type
- Error Detail

### 3. Media Attachments (Photos, Videos, Audio, Documents)

**Sending:** attach a file in the chat. It is uploaded to Salesforce Files and sent to WhatsApp. WhatsApp size limits are checked before sending:

| Type | Max size |
|---|---|
| Image | 5 MB |
| Video | 16 MB |
| Audio | 16 MB |
| Document | 100 MB |

**Receiving:** incoming media is stored with its Meta media id and downloaded in the background (Queueable Apex) into a Salesforce File (`ContentVersion`), up to 8 MB per file.

Media status on each message:

- Pending
- Downloading
- Ready
- Failed (shows a **Retry** link in the chat)
- Too large

### 4. Inbound Webhook Receiver (Apex REST Resource)

Apex class receives real WhatsApp webhook calls:

- Answers Meta's verification request (`hub.mode`, `hub.verify_token`, `hub.challenge`)
- Checks the `X-Hub-Signature-256` signature when an App Secret is configured
- Reads incoming messages (text and media)
- Matches phone → Contact
- Inserts inbound log
- Handles delivery/read receipts

Webhook endpoint:

```
/services/apexrest/whatsappWebhook/
```

### 5. Auto Refresh (1-Second Polling)

LWC polls backend for new messages and updates UI automatically:

- Shows typing indicator for inbound
- Plays notification sound when user is not at bottom
- Starts downloads for new incoming files

### 6. Delete Chat

Apex method:

```apex
WhatsAppOutboundService.deleteChat(contactId)
```

Deletes all WhatsApp messages of selected contact from:

- UI
- Database

---

## 🏗️ Architecture Overview

```
LWC (whatsappChat)
      ⬇️ calls
Apex Controllers (WhatsAppOutboundService, WhatsAppMediaService)
      ⬇️ calls
WhatsApp Cloud API (Meta)
      ⬆️ Webhook posts inbound messages
Apex REST Webhook (WhatsAppInboundService)
      ⬇️ inserts
WhatsApp_Message__c (Custom Object)  ➡️  Salesforce Files (ContentVersion) for media
```

---

## 📦 Components Breakdown

### Lightning Web Component

**whatsappChat**

Handles UI, rendering, input, auto-scroll, notification sound, emoji picker, file upload, media display, retry, delete chat.

Can be placed on a Record Page, App Page, Home Page, Tab, Utility Bar or Inbox.

### Apex Classes

- **WhatsAppOutboundService**: outbound text/template messages + logs + chat history + delete
- **WhatsAppInboundService**: inbound webhook + verification + signature check + status updates
- **WhatsAppMediaService**: send media, download incoming media into Salesforce Files, retry

### Custom Metadata

**WhatsApp_Config__mdt** stores:

- Access_Token__c
- Phone_Number_Id__c
- API_Version__c
- Verify_Token__c
- App_Secret__c
- Default_Country_Code__c

### Custom Object

**WhatsApp_Message__c** fields include:

- Message__c
- Direction__c
- Status__c
- WhatsApp_Message_Id__c
- Message_Time__c
- Contact__c
- Phone__c
- Message_Type__c
- Error_Detail__c
- Media_Id__c
- Content_Version_Id__c
- File_Name__c
- Mime_Type__c
- Media_Status__c

---

## 🔧 Setup Instructions (Step-by-Step)

### 1. Create WhatsApp App (Meta Developer)

- Create Meta App
- Add **"WhatsApp"** Product
- Get:
  - Phone Number ID
  - Access Token
  - App Secret
  - Webhook URL
  - Verify Token (any secret text you choose)

### 2. Create Custom Metadata Type

`WhatsApp_Config__mdt` with fields:

- Access_Token__c
- Phone_Number_Id__c
- API_Version__c (e.g. `v21.0`)
- Verify_Token__c
- App_Secret__c
- Default_Country_Code__c (e.g. `91`)

Create record: **DefaultConfig**

### 3. Create Custom Object

`WhatsApp_Message__c` with the fields listed above. The media fields are included in this repo under `objects/WhatsApp_Message__c/fields`.

### 4. Deploy Apex Classes and LWC

- WhatsAppOutboundService.cls
- WhatsAppInboundService.cls
- WhatsAppMediaService.cls
- whatsappChat (LWC)

```bash
sf project deploy start -d force-app
```

### 5. Configure Remote Site Settings

Add:

```
https://graph.facebook.com
https://lookaside.fbsbx.com
```

(`lookaside.fbsbx.com` is where Meta serves incoming media files.)

### 6. Expose the Webhook (Salesforce Site)

- Create a Salesforce Site
- Give the Site guest user access to the `WhatsAppInboundService` Apex class and the `WhatsApp_Message__c` object

### 7. Configure Webhook

Webhook URL:

```
https://<your-site-domain>/services/apexrest/whatsappWebhook/
```

- Enter the same Verify Token you saved in `WhatsApp_Config__mdt`
- Subscribe to the **messages** field

### 8. Grant Field Access

Give your users read/edit access to the `WhatsApp_Message__c` fields (permission set).

### 9. Add LWC to Record Page

Add **whatsappChat** component to Contact Lightning Record Page.

---

## 🧪 Testing the Flow

### Send Message (Salesforce → WhatsApp)

1. Open Contact record
2. Type text (or attach a file)
3. Hit Send
4. Message appears in UI
5. Message arrives on WhatsApp device

### Inbound Message (WhatsApp → Salesforce)

1. Send message (or photo/document) from phone
2. Webhook receives
3. LWC UI refreshes
4. File downloads into Salesforce Files and shows in the chat
5. Notification sound plays

---

## 📸 UI Screenshots

_(Screenshots coming soon)_

---

## 🧩 Repository Structure

```
/force-app/main/default
    /lwc
        /whatsappChat
            whatsappChat.js
            whatsappChat.html
            whatsappChat.css
    /classes
        WhatsAppOutboundService.cls
        WhatsAppInboundService.cls
        WhatsAppMediaService.cls
    /objects
        /WhatsApp_Message__c
            /fields   (media fields)
```

> `WhatsApp_Config__mdt` and the base `WhatsApp_Message__c` object are created in the org as described in Setup.

---

## 🛡️ Security

- Token stored in Custom Metadata (not hard-coded)
- Webhook verify token check
- Webhook signature validation (`X-Hub-Signature-256` with App Secret)
- WhatsApp file size limits checked before sending; incoming downloads capped at 8 MB
- Incoming files downloaded as the signed-in user, not the Site guest user
- Governor-limit optimized (background Queueable downloads)

---

## 📄 License

MIT License: free to use, modify, enhance.

---

## 🙌 Credits

Developed by **Shaik Imran**, Salesforce Developer
Powered by Meta WhatsApp Cloud API + Salesforce Apex + LWC
