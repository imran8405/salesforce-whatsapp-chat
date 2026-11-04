import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import PING_SOUND from '@salesforce/resourceUrl/WhatsAppPing';
import sendText from '@salesforce/apex/WhatsAppOutboundService.sendText';
import sendTemplate from '@salesforce/apex/WhatsAppOutboundService.sendTemplate';
import getContactInfo from '@salesforce/apex/WhatsAppOutboundService.getContactInfo';
import getMessages from '@salesforce/apex/WhatsAppOutboundService.getMessages';
import deleteChat from '@salesforce/apex/WhatsAppOutboundService.deleteChat';
import prepareMedia from '@salesforce/apex/WhatsAppMediaService.prepareMedia';
import sendMedia from '@salesforce/apex/WhatsAppMediaService.sendMedia';
import requestMediaDownload from '@salesforce/apex/WhatsAppMediaService.requestMediaDownload';
import retryMediaDownload from '@salesforce/apex/WhatsAppMediaService.retryMediaDownload';

const POLL_INTERVAL_MS = 1000; // 1-second polling, as in the original
const TYPING_DELAY_MS = 1500;  // "typing..." shown before a new inbound message appears

export default class WhatsappChat extends LightningElement {
    @api recordId; // Contact Id

    @track messages = [];
    contactName = '';
    contactNumber = '';
    inputText = '';
    showTypingIndicator = false;
    showEmojiPicker = false;
    showScrollDownButton = false;
    showMenu = false;
    showAttachPanel = false;
    unreadCount = 0;
    isSending = false;

    intervalId = null;
    isPolling = false;     // prevents overlapping Apex calls
    isRevealing = false;   // true while the typing indicator is showing
    lastSignature = '';    // "id:status|id:status" of the last rendered list
    lastInboundCount = 0;
    audio = null;
    requestedDownloads = new Set(); // inbound files already asked for

    emojiList = [
        // Smileys
        '😀', '😁', '😂', '🤣', '😃', '😄', '😅', '😆', '😉', '😊', '😇', '🙂', '🙃', '😍', '🥰', '😘', '😗', '😙', '😚',
        '😋', '😛', '😜', '😝', '🤪', '🤨', '🧐', '🤓', '😎', '🤩', '🥳', '😏',
        // Neutral & Sad
        '😒', '😞', '😔', '😟', '😕', '🙁', '☹️', '😣', '😖', '😫', '😩', '🥺', '😢', '😭', '😤', '😠', '😡', '🤬',
        // Emotions
        '🤯', '😳', '🥵', '🥶', '😱', '😨', '😰', '😥', '😓', '🤗', '🤔', '🤭', '🤫', '🤥',
        // Hearts
        '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '💘', '💝', '💖', '💗', '💓', '💕', '💞',
        // Hand Gestures
        '👍', '👎', '👌', '✌️', '🤞', '🤟', '🤘', '🤙', '👋', '🤚', '🖐️', '✋', '🙏', '👏', '🤝', '💪',
        // Person Expressions
        '🤷‍♂️', '🤷‍♀️', '🙋‍♂️', '🙋‍♀️', '🙇‍♂️', '🙇‍♀️', '💁‍♂️', '💁‍♀️', '🙆‍♂️', '🙆‍♀️', '🙅‍♂️', '🙅‍♀️',
        '🕺', '💃',
        // Animals
        '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯', '🦁',
        // Nature
        '🌹', '🌸', '🌼', '🌻', '🌺', '🌷', '🌿', '☘️', '🍀',
        // Food
        '🍏', '🍎', '🍐', '🍓', '🍒', '🍇', '🍉', '🍌', '🍍', '🥭', '🥥', '🥝',
        '🍔', '🍟', '🍕', '🌭', '🍿', '🥤', '🍩', '🍪',
        // Celebrations
        '🎉', '✨', '⭐', '🌟', '⚡', '🔥', '💥', '🎁', '🎈', '🎂',
        // Travel
        '🚗', '🚕', '🚙', '🚌', '🚎', '🏍️', '🚲', '✈️', '🚀',
        // Time
        '⌚', '⏰', '⏳',
        // Objects
        '💡', '📌', '📍', '✏️', '🖊️', '📚', '💼', '📱', '💻', '🖥️', '🖨️', '💾',
        // Symbols
        '✔️', '❌', '‼️', '⁉️', '❓', '❗', '💯', '🔔', '🔕'
    ];

    // ---------------- LIFECYCLE ----------------
    async connectedCallback() {
        this.audio = new Audio(PING_SOUND);
        await this.loadContactHeader();
        await this.loadChatHistory();
        this.scrollToBottom();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.intervalId = setInterval(() => {
            this.autoRefreshMessages();
        }, POLL_INTERVAL_MS);
    }

    disconnectedCallback() {
        if (this.intervalId) {
            clearInterval(this.intervalId);
            this.intervalId = null;
        }
    }

    // ---------------- GETTERS ----------------
    get avatarInitial() {
        if (!this.contactName) {
            return '?';
        }
        return this.contactName.trim().charAt(0).toUpperCase();
    }

    get isEmpty() {
        return this.messages.length === 0;
    }

    get unreadLabel() {
        return this.unreadCount === 1 ? '1 new message' : `${this.unreadCount} new messages`;
    }

    // File types WhatsApp accepts (images, video, audio, documents)
    get acceptedFormats() {
        return ['.jpg', '.jpeg', '.png', '.mp4', '.3gp', '.aac', '.amr', '.mp3', '.m4a', '.ogg',
            '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.csv'];
    }

    // ---------------- LOADING ----------------
    async loadContactHeader() {
        try {
            const data = await getContactInfo({ contactId: this.recordId });
            this.contactName = data.name;
            this.contactNumber = data.phone;
        } catch (error) {
            this.showError('Could not load contact', error);
        }
    }

    async loadChatHistory() {
        try {
            const list = await getMessages({ contactId: this.recordId });
            this.applyList(list);
        } catch (error) {
            this.showError('Could not load chat history', error);
        }
    }

    mapMessages(list) {
        return list.map((msg) => {
            const inbound = msg.Direction__c === 'Inbound';
            const status = msg.Status__c;
            const type = (msg.Message_Type__c || '').toLowerCase();
            const cvId = msg.Content_Version_Id__c;
            const mediaStatus = msg.Media_Status__c;
            const isPicture = type === 'image' || type === 'sticker';
            const isAudioVideo = type === 'video' || type === 'audio';
            let bubbleClass = inbound ? 'bubble inbound-bubble' : 'bubble outbound-bubble';
            if (status === 'Failed') {
                bubbleClass += ' failed-bubble';
            }
            return {
                id: msg.Id,
                text: msg.Message__c,
                time: this.formatTime(msg.Message_Time__c),
                isInbound: inbound,
                isOutbound: !inbound,
                status,
                isSent: status === 'Sent',
                isDelivered: status === 'Delivered',
                isRead: status === 'Read',
                isFailed: status === 'Failed',
                errorDetail: msg.Error_Detail__c || 'Failed',
                rowClass: inbound ? 'message-row inbound' : 'message-row outbound',
                bubbleClass,
                tailClass: inbound ? 'bubble-tail inbound-tail' : 'bubble-tail outbound-tail',
                hasText: !!msg.Message__c,
                fileUrl: cvId ? `/sfc/servlet.shepherd/version/download/${cvId}` : null,
                fileName: msg.File_Name__c || 'Attachment',
                isImage: !!cvId && isPicture,
                isVideo: !!cvId && type === 'video',
                isAudio: !!cvId && type === 'audio',
                isDocument: !!cvId && !isPicture && !isAudioVideo,
                isMediaPending: !cvId && (mediaStatus === 'Pending' || mediaStatus === 'Downloading'),
                isMediaFailed: !cvId && (mediaStatus === 'Failed' || mediaStatus === 'Too large'),
                canRetry: !cvId && mediaStatus === 'Failed',
                mediaNote: mediaStatus === 'Too large'
                    ? 'File too large to show here. Open it on the phone.'
                    : 'Attachment could not be downloaded'
            };
        });
    }

    applyList(list) {
        this.messages = this.mapMessages(list);
        this.lastSignature = this.buildSignature(list);
        this.lastInboundCount = this.countInbound(list);
        this.requestPendingDownloads(list);
    }

    buildSignature(list) {
        return list
            .map((m) => `${m.Id}:${m.Status__c}:${m.Media_Status__c || ''}:${m.Content_Version_Id__c || ''}`)
            .join('|');
    }

    // Incoming photos/files arrive as a Meta media id; ask Apex to download them once
    requestPendingDownloads(list) {
        const ids = list
            .filter((m) => m.Media_Status__c === 'Pending' && !this.requestedDownloads.has(m.Id))
            .map((m) => m.Id);
        if (!ids.length) {
            return;
        }
        ids.forEach((id) => this.requestedDownloads.add(id));
        requestMediaDownload({ messageIds: ids }).catch((error) => {
            ids.forEach((id) => this.requestedDownloads.delete(id));
            console.error('Media download request failed', error);
        });
    }

    countInbound(list) {
        return list.filter((m) => m.Direction__c === 'Inbound').length;
    }

    // ---------------- POLLING ----------------
    async autoRefreshMessages() {
        if (this.isPolling || this.isRevealing || !this.recordId) {
            return;
        }
        this.isPolling = true;
        try {
            const list = await getMessages({ contactId: this.recordId });
            const signature = this.buildSignature(list);
            if (signature === this.lastSignature) {
                return; // nothing changed, no re-render
            }

            const newInbound = Math.max(0, this.countInbound(list) - this.lastInboundCount);
            const atBottom = this.isAtBottom();

            if (newInbound > 0 && atBottom) {
                // At the bottom: show "typing...", then reveal the message
                this.isRevealing = true;
                this.showTypingIndicator = true;
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => {
                    this.showTypingIndicator = false;
                    this.applyList(list);
                    this.isRevealing = false;
                    this.playNotificationSound();
                    this.scrollToBottom();
                }, TYPING_DELAY_MS);
            } else if (newInbound > 0) {
                // Scrolled up: show the "new message" button instead of jumping
                this.applyList(list);
                this.unreadCount += newInbound;
                this.showScrollDownButton = true;
                this.playNotificationSound();
            } else {
                // Tick change (sent/delivered/read/failed) or our own message
                this.applyList(list);
                if (atBottom) {
                    this.scrollToBottom();
                }
            }
        } catch (error) {
            console.error('Auto refresh failed', error);
        } finally {
            this.isPolling = false;
        }
    }

    // ---------------- INPUT & SENDING ----------------
    handleInput(event) {
        this.inputText = event.target.value;
    }

    handleKeyDown(event) {
        if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            this.inputText = event.target.value;
            this.sendMessage();
        }
    }

    async sendMessage() {
        const msgText = (this.inputText || '').trim();
        if (!msgText || this.isSending) {
            return;
        }
        this.isSending = true;
        try {
            const log = await sendText({ contactId: this.recordId, text: msgText });
            this.clearInput();
            this.showEmojiPicker = false;
            if (log && log.Status__c === 'Failed') {
                this.showError('WhatsApp rejected the message', log.Error_Detail__c);
            }
            await this.refreshNow();
            this.scrollToBottom();
        } catch (error) {
            this.showError('Error sending WhatsApp message', error);
        } finally {
            this.isSending = false;
        }
    }

    async handleSendTemplate() {
        this.showMenu = false;
        try {
            const log = await sendTemplate({
                contactId: this.recordId,
                templateName: 'hello_world',
                languageCode: 'en_US'
            });
            if (log && log.Status__c === 'Failed') {
                this.showError('Template failed', log.Error_Detail__c);
            } else {
                this.showToast('Template sent',
                    'Reply on WhatsApp to open the 24-hour window for free-form chat.', 'success');
            }
            await this.refreshNow();
            this.scrollToBottom();
        } catch (error) {
            this.showError('Template send failed', error);
        }
    }

    async refreshNow() {
        const list = await getMessages({ contactId: this.recordId });
        this.applyList(list);
    }

    clearInput() {
        this.inputText = '';
        const inputEl = this.template.querySelector('.chat-input');
        if (inputEl) {
            inputEl.value = '';
        }
    }

    // ---------------- ATTACHMENTS ----------------
    toggleAttachPanel() {
        this.showAttachPanel = !this.showAttachPanel;
        if (this.showAttachPanel) {
            this.showEmojiPicker = false;
            this.showMenu = false;
        }
    }

    // lightning-file-upload has saved the file(s) to the Contact; now send each one
    async handleUploadFinished(event) {
        const files = (event.detail && event.detail.files) || [];
        this.showAttachPanel = false;
        if (!files.length) {
            return;
        }
        this.isSending = true;
        let caption = (this.inputText || '').trim(); // text in the box becomes the caption
        try {
            for (const file of files) {
                const contentVersionId = await prepareMedia({ contentDocumentId: file.documentId });
                const log = await sendMedia({ contactId: this.recordId, contentVersionId, caption });
                if (log && log.Status__c === 'Failed') {
                    this.showError(`WhatsApp rejected ${file.name}`, log.Error_Detail__c);
                }
                caption = ''; // caption only on the first file
            }
            this.clearInput();
            await this.refreshNow();
            this.scrollToBottom();
        } catch (error) {
            this.showError('Error sending attachment', error);
        } finally {
            this.isSending = false;
        }
    }

    // "Retry" on a failed incoming file
    async handleRetryDownload(event) {
        const id = event.currentTarget.dataset.id;
        try {
            this.requestedDownloads.delete(id);
            await retryMediaDownload({ messageId: id });
            await this.refreshNow();
        } catch (error) {
            this.showError('Could not retry the download', error);
        }
    }

    // ---------------- EMOJI ----------------
    toggleEmojiPicker() {
        this.showEmojiPicker = !this.showEmojiPicker;
        if (this.showEmojiPicker) {
            this.showAttachPanel = false;
        }
    }

    handleEmojiClick(event) {
        const emoji = event.currentTarget.dataset.emoji;
        this.inputText = (this.inputText || '') + emoji;
        const inputEl = this.template.querySelector('.chat-input');
        if (inputEl) {
            inputEl.value = this.inputText;
            inputEl.focus();
        }
    }

    // ---------------- MENU ----------------
    toggleMenu() {
        this.showMenu = !this.showMenu;
    }

    async handleDeleteChat() {
        this.showMenu = false;
        const confirmed = await LightningConfirm.open({
            message: 'Delete all WhatsApp messages for this contact? This cannot be undone.',
            label: 'Delete Chat',
            theme: 'warning'
        });
        if (!confirmed) {
            return;
        }
        try {
            await deleteChat({ contactId: this.recordId });
            this.applyList([]);
            this.unreadCount = 0;
            this.showScrollDownButton = false;
            this.showToast('Chat deleted', 'All messages for this contact were removed.', 'success');
        } catch (error) {
            this.showError('Delete chat failed', error);
        }
    }

    // ---------------- SCROLL ----------------
    isAtBottom() {
        const area = this.template.querySelector('.messages-area');
        if (!area) {
            return true;
        }
        return area.scrollTop + area.clientHeight >= area.scrollHeight - 20;
    }

    handleScroll() {
        if (this.isAtBottom()) {
            this.showScrollDownButton = false;
            this.unreadCount = 0;
        }
    }

    scrollDownManually() {
        this.scrollToBottom();
        this.showScrollDownButton = false;
        this.unreadCount = 0;
    }

    scrollToBottom() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const area = this.template.querySelector('.messages-area');
            if (area) {
                try {
                    area.scrollTo({ top: area.scrollHeight, behavior: 'smooth' });
                } catch (e) {
                    area.scrollTop = area.scrollHeight;
                }
            }
        }, 50);
    }

    // ---------------- UTILITIES ----------------
    formatTime(dateTimeString) {
        if (!dateTimeString) {
            return '';
        }
        try {
            return new Date(dateTimeString).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
        } catch (e) {
            return '';
        }
    }

    playNotificationSound() {
        if (!this.audio) {
            return;
        }
        try {
            this.audio.currentTime = 0;
            const playing = this.audio.play();
            if (playing && playing.catch) {
                playing.catch(() => {}); // browsers block sound until the user clicks the page once
            }
        } catch (e) {
            // ignore
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({
            title,
            message,
            variant,
            mode: variant === 'error' ? 'sticky' : 'dismissible'
        }));
    }

    showError(title, error) {
        let message = 'Unknown error';
        if (typeof error === 'string') {
            message = error;
        } else if (error && error.body && error.body.message) {
            message = error.body.message;
        } else if (error && error.body && Array.isArray(error.body.pageErrors) && error.body.pageErrors.length) {
            message = error.body.pageErrors.map((e) => e.message).join(', ');
        } else if (error && error.body && error.body.fieldErrors && Object.keys(error.body.fieldErrors).length) {
            message = Object.values(error.body.fieldErrors).flat().map((e) => e.message).join(', ');
        } else if (error && error.message) {
            message = error.message;
        }
        console.error(title, error);
        // Toasts treat {0}, {1}... as placeholders and drop text in braces, so strip them
        this.showToast(title, String(message).replace(/[{}]/g, ''), 'error');
    }
}