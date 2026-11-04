# Salesforce WhatsApp Chat

A Lightning Web Component and Apex services for sending and receiving WhatsApp messages (via the Meta WhatsApp Cloud API) from Salesforce.

## Contents

| Path | What it is |
|---|---|
| `force-app/main/default/lwc/whatsappChat` | Chat UI: message history, text/template/attachment send, emoji picker, incoming media display with retry |
| `classes/WhatsAppInboundService` | Handles incoming WhatsApp webhook messages |
| `classes/WhatsAppOutboundService` | Sends text, template and attachment messages |
| `classes/WhatsAppMediaService` | Downloads incoming media into Salesforce Files (queueable), with retry |
| `objects/WhatsApp_Message__c/fields` | Media fields: `Media_Id__c`, `Content_Version_Id__c`, `File_Name__c`, `Mime_Type__c`, `Media_Status__c` |

## Prerequisites

The `WhatsApp_Message__c` object itself, its other fields, and the WhatsApp API credentials are not included in this repo and must already exist in the target org.

## Deploy

```
sf project deploy start -d force-app
```

Grant field-level security on the new `WhatsApp_Message__c` fields to the users of the chat component.
