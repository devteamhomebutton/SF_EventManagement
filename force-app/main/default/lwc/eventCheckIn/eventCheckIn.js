import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { getBarcodeScanner } from 'lightning/mobileCapabilities';

import getEventSummary from '@salesforce/apex/BadgeScanService.getEventSummary';
import searchAttendees from '@salesforce/apex/BadgeScanService.searchAttendees';
import processScan from '@salesforce/apex/BadgeScanService.processScan';
import registerWalkUp from '@salesforce/apex/BadgeScanService.registerWalkUp';

const CAMERA = 'Camera Scan';
const MANUAL = 'Manual Check-in';

export default class EventCheckIn extends LightningElement {
    @api recordId;

    @track outcome;
    @track walkUp = {};

    searchTerm = '';
    checkedInOnly = false;
    busy = false;
    scanner;
    cameraAvailable = false;

    summaryResult;
    attendeeResult;

    connectedCallback() {
        // Only returns a scanner inside the Salesforce mobile app; desktop falls
        // back to the badge input, which a USB scanner types into like a keyboard.
        this.scanner = getBarcodeScanner();
        this.cameraAvailable = !!this.scanner && this.scanner.isAvailable();
    }

    @wire(getEventSummary, { eventRegistryId: '$recordId' })
    wiredSummary(result) {
        this.summaryResult = result;
    }

    @wire(searchAttendees, {
        eventRegistryId: '$recordId',
        term: '$searchTerm',
        checkedInOnly: '$checkedInOnly'
    })
    wiredAttendees(result) {
        this.attendeeResult = result;
    }

    get summary() {
        return this.summaryResult && this.summaryResult.data ? this.summaryResult.data : {};
    }

    get attendees() {
        const rows = this.attendeeResult && this.attendeeResult.data ? this.attendeeResult.data : [];

        return rows.map((row) => ({
            ...row,
            rowClass: row.checkedIn ? 'row arrived' : 'row waiting',
            statusLabel: row.checkedIn ? 'Checked in' : 'Expected',
            statusVariant: row.checkedIn ? 'success' : 'inverse',
            buttonLabel: row.checkedIn ? 'Done' : 'Check in',
            disabled: row.checkedIn || this.busy
        }));
    }

    get hasAttendees() {
        return this.attendees.length > 0;
    }

    get eventClosed() {
        return !!this.summary.status && this.summary.status !== 'Active';
    }

    get progressPercent() {
        const total = this.summary.totalAttendees || 0;

        return total === 0 ? 0 : Math.round(((this.summary.checkedIn || 0) / total) * 100);
    }

    get progressStyle() {
        return `width: ${this.progressPercent}%`;
    }

    get outcomeClass() {
        if (!this.outcome) {
            return 'outcome';
        }

        if (this.outcome.success) {
            return 'outcome success';
        }

        return this.outcome.result === 'Already Checked In' ? 'outcome warning' : 'outcome error';
    }

    get outcomeIcon() {
        if (!this.outcome) {
            return '';
        }

        if (this.outcome.success) {
            return 'utility:success';
        }

        return this.outcome.result === 'Already Checked In' ? 'utility:warning' : 'utility:error';
    }

    get scanDisabled() {
        return this.busy || this.eventClosed;
    }

    get cameraUnavailable() {
        return !this.cameraAvailable;
    }

    // ------------------------------------------------------------ scanning

    handleBadgeKey(event) {
        // A USB scanner types the code then sends Enter.
        if (event.key === 'Enter') {
            this.submitScan(event.target.value, MANUAL);
            event.target.value = '';
        }
    }

    handleBadgeSubmit() {
        const input = this.template.querySelector('[data-id="badge"]');

        if (input) {
            this.submitScan(input.value, MANUAL);
            input.value = '';
        }
    }

    async startCameraScan() {
        if (!this.cameraAvailable) {
            return;
        }

        try {
            const options = {
                barcodeTypes: [this.scanner.barcodeTypes.QR, this.scanner.barcodeTypes.CODE_128],
                instructionText: 'Point the camera at a badge',
                successText: 'Badge read'
            };

            let barcode = await this.scanner.beginCapture(options);

            // Continuous mode: keep the camera open until the user dismisses it.
            while (barcode) {
                await this.submitScan(barcode.value, CAMERA);
                barcode = await this.scanner.resumeCapture();
            }
        } catch (error) {
            // Dismissing the scanner is the normal way out, not a failure.
            if (error && error.code !== 'userDismissedScanner') {
                this.showOutcome({
                    result: 'Error',
                    success: false,
                    message: error.message || 'The camera could not be opened.'
                });
            }
        } finally {
            this.scanner.endCapture();
        }
    }

    async submitScan(badgeId, method) {
        if (!badgeId || this.busy) {
            return;
        }

        this.busy = true;

        try {
            const result = await processScan({
                eventRegistryId: this.recordId,
                badgeId,
                scanMethod: method
            });

            this.showOutcome(result);
            await this.refreshAll();
        } catch (error) {
            this.showOutcome({
                result: 'Error',
                success: false,
                message: this.readError(error)
            });
        } finally {
            this.busy = false;
        }
    }

    handleRowCheckIn(event) {
        this.submitScan(event.target.dataset.badge, MANUAL);
    }

    // ------------------------------------------------------------- walk-ups

    handleWalkUpChange(event) {
        this.walkUp = { ...this.walkUp, [event.target.dataset.field]: event.target.value };
    }

    async handleWalkUpSubmit() {
        if (!this.walkUp.lastName) {
            this.showOutcome({
                result: 'Error',
                success: false,
                message: 'A last name is needed to register a walk-up.'
            });

            return;
        }

        this.busy = true;

        try {
            const result = await registerWalkUp({
                eventRegistryId: this.recordId,
                details: this.walkUp
            });

            this.showOutcome(result);

            if (result.success) {
                this.walkUp = {};
                this.template.querySelectorAll('lightning-input[data-field]').forEach((field) => {
                    field.value = null;
                });
            }

            await this.refreshAll();
        } catch (error) {
            this.showOutcome({
                result: 'Error',
                success: false,
                message: this.readError(error)
            });
        } finally {
            this.busy = false;
        }
    }

    // --------------------------------------------------------------- search

    handleSearch(event) {
        this.searchTerm = event.target.value;
    }

    handleFilterToggle(event) {
        this.checkedInOnly = event.target.checked;
    }

    // --------------------------------------------------------------- helpers

    showOutcome(result) {
        this.outcome = result;
    }

    dismissOutcome() {
        this.outcome = undefined;
    }

    async refreshAll() {
        await Promise.all([refreshApex(this.summaryResult), refreshApex(this.attendeeResult)]);
    }

    readError(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }

        return 'Something went wrong. Try again or check in manually.';
    }
}
