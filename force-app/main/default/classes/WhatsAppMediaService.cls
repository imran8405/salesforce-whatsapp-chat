public with sharing class WhatsAppMediaService {

    private static final Integer MB = 1024 * 1024;

    // WhatsApp Cloud API size limits per media type
    private static final Map<String, Integer> MAX_SEND_BYTES = new Map<String, Integer>{
        'image' => 5 * MB, 'video' => 16 * MB, 'audio' => 16 * MB, 'document' => 100 * MB
    };

    // Largest incoming file we download (async Apex has 12 MB of heap)
    private static final Integer MAX_DOWNLOAD_BYTES = 8 * MB;

    // Meta's file server answers with an HTML error page to clients it doesn't recognise
    private static final String USER_AGENT = 'curl/7.64.1';

    private static final Map<String, String> MIME_BY_EXT = new Map<String, String>{
        'jpg'  => 'image/jpeg', 'jpeg' => 'image/jpeg', 'png' => 'image/png', 'webp' => 'image/webp',
        'mp4'  => 'video/mp4',  '3gp'  => 'video/3gpp',
        'aac'  => 'audio/aac',  'amr'  => 'audio/amr', 'mp3' => 'audio/mpeg', 'm4a' => 'audio/mp4',
        'ogg'  => 'audio/ogg',
        'pdf'  => 'application/pdf', 'txt' => 'text/plain', 'csv' => 'text/csv',
        'doc'  => 'application/msword',
        'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'xls'  => 'application/vnd.ms-excel',
        'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'ppt'  => 'application/vnd.ms-powerpoint',
        'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation'
    };

    // =============================================================
    // OUTBOUND, step 1: give the uploaded file a public link that
    // Meta can download (expires after 1 day). Kept separate from
    // sendMedia because Apex can't do a callout after DML.
    // =============================================================
    @AuraEnabled
    public static Id prepareMedia(Id contentDocumentId) {
        if (contentDocumentId == null) {
            throw new AuraHandledException('File is required.');
        }
        ContentVersion cv = [
            SELECT Id, Title
            FROM ContentVersion
            WHERE ContentDocumentId = :contentDocumentId AND IsLatest = true
            LIMIT 1
        ];
        List<ContentDistribution> existing = [
            SELECT Id FROM ContentDistribution WHERE ContentVersionId = :cv.Id LIMIT 1
        ];
        if (existing.isEmpty()) {
            insert new ContentDistribution(
                Name                             = (String.isBlank(cv.Title) ? 'WhatsApp file' : cv.Title).left(100),
                ContentVersionId                 = cv.Id,
                PreferencesAllowViewInBrowser    = true,
                PreferencesAllowOriginalDownload = true,
                PreferencesLinkLatestVersion     = true,
                PreferencesNotifyOnVisit         = false,
                PreferencesPasswordRequired      = false,
                PreferencesExpires               = true,
                ExpiryDate                       = System.now().addDays(1)
            );
        }
        return cv.Id;
    }

    // =============================================================
    // OUTBOUND, step 2: send the file as an image/video/audio/document message
    // =============================================================
    @AuraEnabled
    public static WhatsApp_Message__c sendMedia(Id contactId, Id contentVersionId, String caption) {
        if (contactId == null || contentVersionId == null) {
            throw new AuraHandledException('Contact and file are required.');
        }
        ContentVersion cv = [
            SELECT Id, Title, FileExtension, ContentSize
            FROM ContentVersion
            WHERE Id = :contentVersionId
            LIMIT 1
        ];
        List<ContentDistribution> links = [
            SELECT ContentDownloadUrl
            FROM ContentDistribution
            WHERE ContentVersionId = :cv.Id
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (links.isEmpty() || String.isBlank(links[0].ContentDownloadUrl)) {
            throw new AuraHandledException('Could not create a public link for this file. '
                + 'Turn on Setup > Content Deliveries and Public Links.');
        }

        String ext    = cv.FileExtension == null ? '' : cv.FileExtension.toLowerCase();
        String waType = waTypeFor(ext);
        if (cv.ContentSize > MAX_SEND_BYTES.get(waType)) {
            throw new AuraHandledException('This ' + waType + ' is ' + (cv.ContentSize / MB) + ' MB. WhatsApp allows up to '
                + (MAX_SEND_BYTES.get(waType) / MB) + ' MB for ' + waType + ' files.');
        }

        String title    = String.isBlank(cv.Title) ? 'file' : cv.Title;
        String fileName = (String.isBlank(ext) || title.toLowerCase().endsWith('.' + ext)) ? title : title + '.' + ext;

        Map<String, Object> media = new Map<String, Object>{ 'link' => links[0].ContentDownloadUrl };
        if (String.isNotBlank(caption) && waType != 'audio') {
            media.put('caption', caption);
        }
        if (waType == 'document') {
            media.put('filename', fileName);
        }
        Map<String, Object> payload = new Map<String, Object>{
            'messaging_product' => 'whatsapp',
            'recipient_type'    => 'individual',
            'type'              => waType
        };
        payload.put(waType, media);

        WhatsApp_Message__c log = new WhatsApp_Message__c(
            Message__c            = String.isNotBlank(caption) ? caption : null,
            Message_Type__c       = capitalize(waType),
            Content_Version_Id__c = cv.Id,
            File_Name__c          = fileName,
            Mime_Type__c          = MIME_BY_EXT.containsKey(ext) ? MIME_BY_EXT.get(ext) : 'application/octet-stream',
            Media_Status__c       = 'Ready'
        );
        return WhatsAppOutboundService.sendToContact(contactId, payload, log);
    }

    // =============================================================
    // INBOUND: the chat asks for files that arrived via the webhook.
    // The download runs as the signed-in user (not the Site guest user),
    // so the saved file is owned by a normal user.
    // =============================================================
    @AuraEnabled
    public static void requestMediaDownload(List<Id> messageIds) {
        if (messageIds == null || messageIds.isEmpty()) {
            return;
        }
        List<WhatsApp_Message__c> pending = [
            SELECT Id, Media_Status__c
            FROM WhatsApp_Message__c
            WHERE Id IN :messageIds AND Media_Status__c = 'Pending' AND Media_Id__c != null
            LIMIT 20
            FOR UPDATE
        ];
        if (pending.isEmpty()) {
            return;
        }
        for (WhatsApp_Message__c m : pending) {
            m.Media_Status__c = 'Downloading';
        }
        update pending;
        for (WhatsApp_Message__c m : pending) {
            System.enqueueJob(new Downloader(m.Id));
        }
    }

    // "Retry" link in the chat: put a failed download back in the queue
    @AuraEnabled
    public static void retryMediaDownload(Id messageId) {
        List<WhatsApp_Message__c> msgs = [
            SELECT Id
            FROM WhatsApp_Message__c
            WHERE Id = :messageId AND Media_Id__c != null AND Content_Version_Id__c = null
            LIMIT 1
        ];
        if (msgs.isEmpty()) {
            return;
        }
        msgs[0].Media_Status__c = 'Pending';
        msgs[0].Error_Detail__c = null;
        update msgs;
    }

    public with sharing class Downloader implements Queueable, Database.AllowsCallouts {
        private Id messageId;

        public Downloader(Id messageId) {
            this.messageId = messageId;
        }

        public void execute(QueueableContext context) {
            WhatsApp_Message__c msg = [
                SELECT Id, Contact__c, Media_Id__c, Mime_Type__c, File_Name__c, Message_Type__c
                FROM WhatsApp_Message__c
                WHERE Id = :messageId
                LIMIT 1
            ];
            try {
                WhatsApp_Config__mdt cfg = WhatsAppOutboundService.getConfig();
                String apiVersion = String.isBlank(cfg.API_Version__c) ? 'v26.0' : cfg.API_Version__c.trim();
                String token = cfg.Access_Token__c.trim();

                // 1. Ask Meta for a short-lived download URL
                HttpResponse infoRes = WhatsAppMediaService.httpGet(
                    'https://graph.facebook.com/' + apiVersion + '/' + msg.Media_Id__c, token, 30000);
                if (infoRes.getStatusCode() != 200) {
                    finish(msg, 'Failed', 'Media lookup HTTP ' + infoRes.getStatusCode() + ' | ' + infoRes.getBody());
                    return;
                }
                Map<String, Object> info = (Map<String, Object>) JSON.deserializeUntyped(infoRes.getBody());
                String url = (String) info.get('url');
                Long size = info.get('file_size') == null ? 0 : Long.valueOf(String.valueOf(info.get('file_size')));
                if (size > WhatsAppMediaService.MAX_DOWNLOAD_BYTES) {
                    finish(msg, 'Too large', 'File is ' + (size / WhatsAppMediaService.MB) + ' MB; the chat downloads files up to '
                        + (WhatsAppMediaService.MAX_DOWNLOAD_BYTES / WhatsAppMediaService.MB) + ' MB.');
                    return;
                }

                // 2. Download the file itself (same token; host lookaside.fbsbx.com)
                HttpResponse fileRes = WhatsAppMediaService.httpGet(url, token, 120000);
                String contentType = fileRes.getHeader('Content-Type');
                if (fileRes.getStatusCode() != 200 || (contentType != null && contentType.startsWith('text/html'))) {
                    finish(msg, 'Failed', 'Download HTTP ' + fileRes.getStatusCode() + ' (' + contentType + ') from '
                        + url.substringBefore('?'));
                    return;
                }

                // 3. Save it as a Salesforce File on the Contact (or on the message if no Contact matched)
                String mime = String.isNotBlank(msg.Mime_Type__c) ? msg.Mime_Type__c : (String) info.get('mime_type');
                String fileName = String.isNotBlank(msg.File_Name__c)
                    ? msg.File_Name__c
                    : 'WhatsApp ' + (String.isBlank(msg.Message_Type__c) ? 'file' : msg.Message_Type__c.toLowerCase())
                      + ' ' + System.now().format('yyyy-MM-dd HHmmss') + '.' + WhatsAppMediaService.extForMime(mime);

                ContentVersion cv = new ContentVersion(
                    Title                  = fileName,
                    PathOnClient           = fileName,
                    VersionData            = fileRes.getBodyAsBlob(),
                    FirstPublishLocationId = msg.Contact__c != null ? msg.Contact__c : msg.Id
                );
                insert cv;

                msg.Content_Version_Id__c = cv.Id;
                msg.File_Name__c          = fileName;
                msg.Mime_Type__c          = mime;
                finish(msg, 'Ready', null);
            } catch (Exception ex) {
                finish(msg, 'Failed', ex.getMessage());
            }
        }

        private void finish(WhatsApp_Message__c msg, String status, String detail) {
            msg.Media_Status__c = status;
            if (detail != null) {
                msg.Error_Detail__c = detail.left(32000);
            }
            update msg;
        }
    }

    // =============================================================
    // HELPERS
    // =============================================================

    // GET with the Bearer token and a User-Agent; follows up to 3 redirects
    // (Apex does not follow redirects on its own)
    private static HttpResponse httpGet(String url, String token, Integer timeoutMs) {
        HttpResponse res;
        for (Integer hop = 0; hop < 4; hop++) {
            HttpRequest req = new HttpRequest();
            req.setMethod('GET');
            req.setEndpoint(url);
            req.setHeader('Authorization', 'Bearer ' + token);
            req.setHeader('User-Agent', USER_AGENT);
            req.setTimeout(timeoutMs);
            res = new Http().send(req);
            Integer code = res.getStatusCode();
            String redirectTo = res.getHeader('Location');
            if ((code == 301 || code == 302 || code == 303 || code == 307 || code == 308) && String.isNotBlank(redirectTo)) {
                url = redirectTo;
                continue;
            }
            break;
        }
        return res;
    }

    private static String waTypeFor(String ext) {
        if (ext == 'jpg' || ext == 'jpeg' || ext == 'png') {
            return 'image';
        }
        if (ext == 'mp4' || ext == '3gp') {
            return 'video';
        }
        if (ext == 'aac' || ext == 'amr' || ext == 'mp3' || ext == 'm4a' || ext == 'ogg') {
            return 'audio';
        }
        return 'document';
    }

    private static String extForMime(String mime) {
        if (String.isBlank(mime)) {
            return 'bin';
        }
        String base = mime.split(';')[0].trim().toLowerCase();
        for (String ext : MIME_BY_EXT.keySet()) {
            if (MIME_BY_EXT.get(ext) == base) {
                return ext;
            }
        }
        return 'bin';
    }

    private static String capitalize(String s) {
        return s.substring(0, 1).toUpperCase() + s.substring(1);
    }
}