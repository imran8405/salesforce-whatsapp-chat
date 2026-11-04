@RestResource(urlMapping='/whatsappWebhook/*')
global without sharing class WhatsAppInboundService {

    // Higher rank wins, so a late "delivered" never overwrites "read"
    private static final Map<String, Integer> STATUS_RANK = new Map<String, Integer>{
        'Sent' => 1, 'Delivered' => 2, 'Read' => 3, 'Failed' => 4
    };

    // Message types that carry a file
    private static final Set<String> MEDIA_TYPES = new Set<String>{
        'image', 'video', 'audio', 'document', 'sticker'
    };

    // =============================================================
    // GET: one-time webhook verification by Meta
    // =============================================================
    @HttpGet
    global static void verifyWebhook() {
        RestRequest req  = RestContext.request;
        RestResponse res = RestContext.response;

        String mode      = req.params.get('hub.mode');
        String token     = req.params.get('hub.verify_token');
        String challenge = req.params.get('hub.challenge');

        String expectedToken = WhatsAppOutboundService.getConfig().Verify_Token__c;

        // equals() is case-sensitive; Apex == is not
        if (mode == 'subscribe' && token != null && expectedToken != null
                && token.equals(expectedToken) && challenge != null) {
            res.statusCode = 200;
            res.addHeader('Content-Type', 'text/plain');
            res.responseBody = Blob.valueOf(challenge);
        } else {
            res.statusCode = 403;
        }
    }

    // =============================================================
    // POST: incoming messages + sent/delivered/read/failed statuses
    // =============================================================
    @HttpPost
    global static void receiveWebhook() {
        RestRequest req  = RestContext.request;
        RestResponse res = RestContext.response;
        res.statusCode = 200;

        try {
            if (req.requestBody == null || req.requestBody.size() == 0) {
                res.statusCode = 400;
                return;
            }

            WhatsApp_Config__mdt cfg = WhatsAppOutboundService.getConfig();

            // Security: accept only calls signed by Meta (skipped while App Secret is blank)
            if (String.isNotBlank(cfg.App_Secret__c)
                    && !isValidSignature(req, cfg.App_Secret__c.trim())) {
                System.debug(LoggingLevel.WARN, 'Rejected webhook: invalid X-Hub-Signature-256');
                res.statusCode = 403;
                return;
            }

            String rawBody = req.requestBody.toString();
            System.debug('WhatsApp webhook body --> ' + rawBody);

            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(rawBody);
            List<Object> entries = (List<Object>) root.get('entry');
            if (entries == null) {
                return;
            }

            List<Map<String, Object>> inboundMsgs = new List<Map<String, Object>>();
            List<Map<String, Object>> statusList  = new List<Map<String, Object>>();

            for (Object entryObj : entries) {
                List<Object> changes = (List<Object>) ((Map<String, Object>) entryObj).get('changes');
                if (changes == null) {
                    continue;
                }
                for (Object changeObj : changes) {
                    Map<String, Object> value =
                        (Map<String, Object>) ((Map<String, Object>) changeObj).get('value');
                    if (value == null) {
                        continue;
                    }
                    List<Object> msgs = (List<Object>) value.get('messages');
                    if (msgs != null) {
                        for (Object m : msgs) {
                            inboundMsgs.add((Map<String, Object>) m);
                        }
                    }
                    List<Object> statuses = (List<Object>) value.get('statuses');
                    if (statuses != null) {
                        for (Object s : statuses) {
                            statusList.add((Map<String, Object>) s);
                        }
                    }
                }
            }

            if (!inboundMsgs.isEmpty()) {
                insertInboundMessages(inboundMsgs);
            }
            if (!statusList.isEmpty()) {
                processStatusUpdates(statusList);
            }
        } catch (Exception ex) {
            // Still answer 200: a non-200 makes Meta retry the same payload for days
            System.debug(LoggingLevel.ERROR, '### Webhook error: ' + ex.getMessage()
                         + '\n' + ex.getStackTraceString());
        }
    }

    // =============================================================
    // INBOUND MESSAGES
    // =============================================================
    private static void insertInboundMessages(List<Map<String, Object>> msgs) {
        // Skip messages already saved (Meta can deliver the same webhook twice)
        Set<String> waIds = new Set<String>();
        for (Map<String, Object> m : msgs) {
            if (m.get('id') != null) {
                waIds.add((String) m.get('id'));
            }
        }
        Set<String> existing = new Set<String>();
        for (WhatsApp_Message__c old : [
                SELECT WhatsApp_Message_Id__c FROM WhatsApp_Message__c
                WHERE WhatsApp_Message_Id__c IN :waIds]) {
            existing.add(old.WhatsApp_Message_Id__c);
        }

        Map<String, Contact> contactByPhone = new Map<String, Contact>();
        List<WhatsApp_Message__c> logs = new List<WhatsApp_Message__c>();

        for (Map<String, Object> m : msgs) {
            String waMsgId   = (String) m.get('id');
            String fromPhone = (String) m.get('from');
            if (String.isBlank(fromPhone) || (waMsgId != null && existing.contains(waMsgId))) {
                continue;
            }
            if (!contactByPhone.containsKey(fromPhone)) {
                contactByPhone.put(fromPhone, findContactByPhone(fromPhone));
            }
            Contact related = contactByPhone.get(fromPhone);
            String waType = (String) m.get('type');

            WhatsApp_Message__c log = new WhatsApp_Message__c(
                Contact__c             = (related == null) ? null : related.Id,
                Phone__c               = fromPhone,
                WhatsApp_Message_Id__c = waMsgId,
                Direction__c           = 'Inbound',
                Message_Time__c        = toDatetime(m.get('timestamp')),
                Status__c              = 'Delivered',
                Message_Type__c        = formatMessageType(waType),
                Message__c             = extractText(m, waType)
            );
            applyMedia(log, m, waType);
            logs.add(log);
            if (waMsgId != null) {
                existing.add(waMsgId);
            }
        }

        if (!logs.isEmpty()) {
            for (Database.SaveResult sr : Database.insert(logs, false)) {
                if (!sr.isSuccess()) {
                    System.debug(LoggingLevel.ERROR, 'Inbound insert failed: ' + sr.getErrors());
                }
            }
        }
    }

    // Photos, videos, voice notes, documents and stickers: store Meta's media id.
    // The file itself is downloaded later by WhatsAppMediaService when the chat is open.
    private static void applyMedia(WhatsApp_Message__c log, Map<String, Object> m, String waType) {
        String t = (waType == null) ? '' : waType.toLowerCase();
        if (!MEDIA_TYPES.contains(t) || !(m.get(t) instanceof Map<String, Object>)) {
            return;
        }
        Map<String, Object> media = (Map<String, Object>) m.get(t);
        log.Media_Id__c     = (String) media.get('id');
        log.Mime_Type__c    = (String) media.get('mime_type');
        log.File_Name__c    = media.get('filename') == null ? null : String.valueOf(media.get('filename'));
        log.Media_Status__c = 'Pending';
        log.Message__c      = media.get('caption') == null ? null : String.valueOf(media.get('caption'));
    }

    // Readable text for every WhatsApp message type
    private static String extractText(Map<String, Object> m, String waType) {
        String t = (waType == null) ? '' : waType.toLowerCase();
        Map<String, Object> part = (m.get(t) instanceof Map<String, Object>)
            ? (Map<String, Object>) m.get(t)
            : new Map<String, Object>();

        if (t == 'text') {
            return (String) part.get('body');
        }
        if (t == 'button') {
            return (String) part.get('text');
        }
        if (t == 'reaction') {
            return 'Reacted ' + String.valueOf(part.get('emoji'));
        }
        if (t == 'location') {
            return '[Location] ' + String.valueOf(part.get('latitude')) + ', '
                   + String.valueOf(part.get('longitude'));
        }
        if (t == 'interactive') {
            for (String k : new List<String>{ 'button_reply', 'list_reply' }) {
                if (part.get(k) instanceof Map<String, Object>) {
                    return (String) ((Map<String, Object>) part.get(k)).get('title');
                }
            }
        }
        if (part.get('caption') != null) {
            return '[' + formatMessageType(t) + '] ' + String.valueOf(part.get('caption'));
        }
        return '[' + formatMessageType(t) + ' message]';
    }

    private static Datetime toDatetime(Object unixSeconds) {
        try {
            if (unixSeconds != null) {
                return Datetime.newInstance(Long.valueOf(String.valueOf(unixSeconds)) * 1000L);
            }
        } catch (Exception e) {
            System.debug('Bad timestamp: ' + String.valueOf(unixSeconds));
        }
        return System.now();
    }

    private static String formatMessageType(String waType) {
        if (String.isBlank(waType)) {
            return 'Text';
        }
        String lower = waType.toLowerCase();
        return lower.substring(0, 1).toUpperCase() + lower.substring(1);
    }

    // =============================================================
    // FIND CONTACT BY PHONE (ignores +, spaces, brackets, dashes)
    // =============================================================
    public static Contact findContactByPhone(String fromPhone) {
        String digits = (fromPhone == null) ? '' : fromPhone.replaceAll('[^0-9]', '');
        if (digits.length() < 7) {
            return null;
        }
        String last10 = (digits.length() > 10) ? digits.right(10) : digits;
        String likePattern = '%' + digits.right(4);

        for (Contact c : [
                SELECT Id, Phone, MobilePhone FROM Contact
                WHERE Phone LIKE :likePattern OR MobilePhone LIKE :likePattern
                ORDER BY LastModifiedDate DESC
                LIMIT 200]) {
            for (String p : new List<String>{ c.Phone, c.MobilePhone }) {
                String pd = (p == null) ? '' : p.replaceAll('[^0-9]', '');
                if (pd == digits || (pd.length() >= 10 && pd.right(10) == last10)) {
                    return c;
                }
            }
        }
        System.debug('NO CONTACT MATCH FOUND for ' + fromPhone);
        return null;
    }

    // =============================================================
    // STATUS UPDATES (sent / delivered / read / failed)
    // =============================================================
    private static void processStatusUpdates(List<Map<String, Object>> statusList) {
        Set<String> waIds = new Set<String>();
        for (Map<String, Object> s : statusList) {
            if (s.get('id') != null) {
                waIds.add((String) s.get('id'));
            }
        }

        Map<String, WhatsApp_Message__c> byWaId = new Map<String, WhatsApp_Message__c>();
        for (WhatsApp_Message__c m : [
                SELECT Id, Status__c, WhatsApp_Message_Id__c
                FROM WhatsApp_Message__c
                WHERE WhatsApp_Message_Id__c IN :waIds]) {
            byWaId.put(m.WhatsApp_Message_Id__c, m);
        }

        Map<Id, WhatsApp_Message__c> toUpdate = new Map<Id, WhatsApp_Message__c>();
        for (Map<String, Object> s : statusList) {
            WhatsApp_Message__c rec = byWaId.get((String) s.get('id'));
            String newStatus = mapStatus((String) s.get('status'));
            System.debug('### WA STATUS: id=' + String.valueOf(s.get('id')) + ' status=' + newStatus);
            if (rec == null || newStatus == null) {
                continue;
            }
            Integer oldRank = STATUS_RANK.containsKey(rec.Status__c) ? STATUS_RANK.get(rec.Status__c) : 0;
            if (STATUS_RANK.get(newStatus) <= oldRank) {
                continue;
            }
            rec.Status__c = newStatus;
            if (newStatus == 'Failed') {
                rec.Error_Detail__c = describeErrors(s.get('errors'));
            }
            toUpdate.put(rec.Id, rec);
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate.values();
        }
    }

    private static String mapStatus(String waStatus) {
        if (waStatus == 'sent')      { return 'Sent'; }
        if (waStatus == 'delivered') { return 'Delivered'; }
        if (waStatus == 'read')      { return 'Read'; }
        if (waStatus == 'failed')    { return 'Failed'; }
        return null;
    }

    // e.g. "131047 - Re-engagement message (Message failed to send because more than 24 hours...)"
    private static String describeErrors(Object errorsObj) {
        if (!(errorsObj instanceof List<Object>)) {
            return 'Failed (no details from Meta)';
        }
        List<String> parts = new List<String>();
        for (Object o : (List<Object>) errorsObj) {
            Map<String, Object> err = (Map<String, Object>) o;
            String line = String.valueOf(err.get('code')) + ' - ' + String.valueOf(err.get('title'));
            if (err.get('error_data') instanceof Map<String, Object>) {
                Object details = ((Map<String, Object>) err.get('error_data')).get('details');
                if (details != null) {
                    line += ' (' + String.valueOf(details) + ')';
                }
            }
            parts.add(line);
        }
        return String.join(parts, '; ');
    }

    // =============================================================
    // SIGNATURE CHECK: HMAC-SHA256 of the raw body with the App Secret
    // =============================================================
    private static Boolean isValidSignature(RestRequest req, String appSecret) {
        String header;
        for (String key : req.headers.keySet()) {
            if (key != null && key.equalsIgnoreCase('X-Hub-Signature-256')) {
                header = req.headers.get(key);
            }
        }
        if (String.isBlank(header) || !header.startsWith('sha256=')) {
            return false;
        }
        Blob mac = Crypto.generateMac('hmacSHA256', req.requestBody, Blob.valueOf(appSecret));
        return header.substring(7).equalsIgnoreCase(EncodingUtil.convertToHex(mac));
    }
}