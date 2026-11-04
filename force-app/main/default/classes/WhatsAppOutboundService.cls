public with sharing class WhatsAppOutboundService {

    private static final String DEFAULT_API_VERSION = 'v26.0';

    // Wrapper for the LWC header (name + phone)
    public class ContactHeader {
        @AuraEnabled public String name;
        @AuraEnabled public String phone;
        public ContactHeader(String n, String p) {
            name = n;
            phone = p;
        }
    }

    // ---------------------------------------------------------------
    // CONFIG: SOQL instead of getInstance(), because getInstance()
    // returns only the first 255 characters of long text fields and
    // permanent Meta tokens are often longer than that.
    // ---------------------------------------------------------------
    public static WhatsApp_Config__mdt getConfig() {
        List<WhatsApp_Config__mdt> cfgs = [
            SELECT Access_Token__c, Phone_Number_Id__c, Verify_Token__c,
                   App_Secret__c, API_Version__c, Default_Country_Code__c
            FROM WhatsApp_Config__mdt
            WHERE DeveloperName = 'DefaultConfig'
            LIMIT 1
        ];
        if (cfgs.isEmpty()) {
            throw new AuraHandledException(
                'WhatsApp config not found. Create a WhatsApp_Config__mdt record named "DefaultConfig".');
        }
        return cfgs[0];
    }

    // Turns "+91 98765-43210", "098765 43210" or "9876543210" into "919876543210"
    public static String normalizePhone(String rawPhone, String defaultCountryCode) {
        if (String.isBlank(rawPhone)) {
            return null;
        }
        String digits = rawPhone.replaceAll('[^0-9]', '');
        if (digits.startsWith('00')) {
            digits = digits.substring(2);              // 0091... international prefix
        }
        if (digits.length() == 11 && digits.startsWith('0')) {
            digits = digits.substring(1);              // 0 + 10-digit local number
        }
        if (digits.length() == 10 && String.isNotBlank(defaultCountryCode)) {
            digits = defaultCountryCode.replaceAll('[^0-9]', '') + digits;
        }
        return digits;
    }

    // ---------------------------------------------------------------
    // SEND FREE-FORM TEXT (works only inside the 24-hour window)
    // ---------------------------------------------------------------
    @AuraEnabled
    public static WhatsApp_Message__c sendText(Id contactId, String text) {
        if (contactId == null) {
            throw new AuraHandledException('Contact Id is required.');
        }
        if (String.isBlank(text)) {
            throw new AuraHandledException('Message text cannot be empty.');
        }

        Map<String, Object> payload = new Map<String, Object>{
            'messaging_product' => 'whatsapp',
            'recipient_type'    => 'individual',
            'type'              => 'text',
            'text'              => new Map<String, Object>{
                'preview_url' => false,
                'body'        => text
            }
        };
        return sendToContact(contactId, payload, text, 'Text');
    }

    // ---------------------------------------------------------------
    // SEND AN APPROVED TEMPLATE (works any time, e.g. hello_world)
    // ---------------------------------------------------------------
    @AuraEnabled
    public static WhatsApp_Message__c sendTemplate(Id contactId, String templateName, String languageCode) {
        if (contactId == null) {
            throw new AuraHandledException('Contact Id is required.');
        }
        String tpl  = String.isBlank(templateName) ? 'hello_world' : templateName;
        String lang = String.isBlank(languageCode) ? 'en_US' : languageCode;

        Map<String, Object> payload = new Map<String, Object>{
            'messaging_product' => 'whatsapp',
            'type'              => 'template',
            'template'          => new Map<String, Object>{
                'name'     => tpl,
                'language' => new Map<String, Object>{ 'code' => lang }
            }
        };
        return sendToContact(contactId, payload, '[Template: ' + tpl + ']', 'Template');
    }

    // Turns Meta's error JSON into e.g. "HTTP 400 | 131030 - (#131030) Recipient phone number not in allowed list"
    private static String describeHttpError(HttpResponse res) {
        String summary = 'HTTP ' + res.getStatusCode();
        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Map<String, Object> err = (Map<String, Object>) body.get('error');
            if (err != null) {
                summary += ' | ' + String.valueOf(err.get('code')) + ' - ' + String.valueOf(err.get('message'));
                if (err.get('error_data') instanceof Map<String, Object>) {
                    Object details = ((Map<String, Object>) err.get('error_data')).get('details');
                    if (details != null) {
                        summary += ' (' + String.valueOf(details) + ')';
                    }
                }
                return summary;
            }
        } catch (Exception e) {
            System.debug('Non-JSON error body: ' + res.getBody());
        }
        return summary + ' | ' + res.getBody();
    }

    // Shared callout + logging (also used by WhatsAppMediaService for attachments)
    public static WhatsApp_Message__c sendToContact(Id contactId, Map<String, Object> payload,
                                                    String logText, String msgType) {
        return sendToContact(contactId, payload,
            new WhatsApp_Message__c(Message__c = logText, Message_Type__c = msgType));
    }

    public static WhatsApp_Message__c sendToContact(Id contactId, Map<String, Object> payload,
                                                    WhatsApp_Message__c log) {
        WhatsApp_Config__mdt cfg = getConfig();
        if (String.isBlank(cfg.Phone_Number_Id__c) || String.isBlank(cfg.Access_Token__c)) {
            throw new AuraHandledException(
                'WhatsApp configuration is incomplete. Fill Phone_Number_Id__c and Access_Token__c in DefaultConfig.');
        }

        Contact c = [SELECT Id, Phone FROM Contact WHERE Id = :contactId LIMIT 1];
        String toPhone = normalizePhone(c.Phone, cfg.Default_Country_Code__c);
        if (String.isBlank(toPhone)) {
            throw new AuraHandledException('Contact does not have a Phone number.');
        }
        payload.put('to', toPhone);

        String apiVersion = String.isBlank(cfg.API_Version__c) ? DEFAULT_API_VERSION : cfg.API_Version__c.trim();

        HttpRequest req = new HttpRequest();
        req.setMethod('POST');
        req.setEndpoint('https://graph.facebook.com/' + apiVersion + '/'
                        + cfg.Phone_Number_Id__c.trim() + '/messages');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + cfg.Access_Token__c.trim());
        req.setTimeout(20000);
        req.setBody(JSON.serialize(payload));
        System.debug('WhatsApp payload -> ' + req.getBody());

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (Exception ex) {
            throw new AuraHandledException('WhatsApp callout failed: ' + ex.getMessage());
        }
        System.debug('WhatsApp response ' + res.getStatusCode() + ' ' + res.getBody());

        log.Contact__c      = contactId;
        log.Phone__c        = toPhone;
        log.Direction__c    = 'Outbound';
        log.Message_Time__c = System.now();

        if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object> msgList = (List<Object>) body.get('messages');
            if (msgList != null && !msgList.isEmpty()) {
                log.WhatsApp_Message_Id__c = (String) ((Map<String, Object>) msgList[0]).get('id');
            }
            log.Status__c = 'Sent';
        } else {
            log.Status__c = 'Failed';
            log.Error_Detail__c = describeHttpError(res);
        }

        try {
            insert log;
        } catch (DmlException ex) {
            // The message already reached WhatsApp; only the Salesforce save failed
            throw new AuraHandledException('Sent to WhatsApp, but saving it in Salesforce failed: '
                + String.valueOf(ex.getDmlType(0)) + ' - ' + ex.getDmlMessage(0)
                + ' ' + String.valueOf(ex.getDmlFieldNames(0)));
        }
        return log;
    }

    // ---------------------------------------------------------------
    // LWC HELPERS
    // ---------------------------------------------------------------
    @AuraEnabled(cacheable=true)
    public static ContactHeader getContactInfo(Id contactId) {
        Contact c = [SELECT Id, Name, Phone FROM Contact WHERE Id = :contactId LIMIT 1];
        return new ContactHeader(c.Name, c.Phone);
    }

    @AuraEnabled
    public static List<WhatsApp_Message__c> getMessages(Id contactId) {
        return [
            SELECT Id, Message__c, Message_Time__c, Direction__c, Message_Type__c,
                   Status__c, WhatsApp_Message_Id__c, Error_Detail__c,
                   Content_Version_Id__c, File_Name__c, Mime_Type__c, Media_Status__c
            FROM WhatsApp_Message__c
            WHERE Contact__c = :contactId
            ORDER BY Message_Time__c ASC, CreatedDate ASC
            LIMIT 1000
        ];
    }

    @AuraEnabled
    public static void deleteChat(Id contactId) {
        if (contactId == null) {
            throw new AuraHandledException('Contact Id is required');
        }
        List<WhatsApp_Message__c> msgs = [
            SELECT Id FROM WhatsApp_Message__c WHERE Contact__c = :contactId
        ];
        if (!msgs.isEmpty()) {
            delete msgs;
        }
    }
}