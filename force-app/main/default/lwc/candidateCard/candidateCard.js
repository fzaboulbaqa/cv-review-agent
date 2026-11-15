import { LightningElement, api, wire } from "lwc";
import { getRecord } from "lightning/uiRecordApi";
import { NavigationMixin } from "lightning/navigation";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getCard from "@salesforce/apex/CandidateCardController.getCard";
import setPhoto from "@salesforce/apex/CandidateCardController.setPhoto";
import LAST_MODIFIED_FIELD from "@salesforce/schema/Candidate__c.LastModifiedDate";
import {
  NOT_FOUND_TEXT,
  errorMessage,
  initials,
  scoreLevel,
  subtitle
} from "c/candidateUtils";

const MAX_SKILLS_SHOWN = 5;
const PHOTO_FORMATS = [".png", ".jpg", ".jpeg", ".gif", ".webp"];
const FLAG_TYPES = [
  {
    type: "Missing",
    countField: "missingCount",
    badgeClass: "slds-theme_warning"
  },
  {
    type: "Inferred",
    countField: "inferredCount",
    badgeClass: "slds-badge_inverse"
  },
  {
    type: "Conflict",
    countField: "conflictCount",
    badgeClass: "slds-theme_error"
  }
];

/**
 * Compact Candidate Card. Two ways to use it:
 *  - In a list: the parent passes the data in `candidate` (see jobApplicants). The name links to
 *    the candidate, the score and "View application" show when the data has an application.
 *  - On the Candidate record page: no `candidate` given, so the card loads itself from `recordId`,
 *    reloads when the record is saved, and offers the photo upload.
 */
export default class CandidateCard extends NavigationMixin(LightningElement) {
  @api recordId;
  @api candidate;

  loadedCandidate;
  error;
  isLoading = false;
  isPhotoUploadOpen = false;
  photoFormats = PHOTO_FORMATS;
  lastModified;

  // Record page mode only: '$recordPageId' is undefined in list mode, so the wire doesn't run.
  @wire(getRecord, { recordId: "$recordPageId", fields: [LAST_MODIFIED_FIELD] })
  wiredRecord({ data, error }) {
    if (data) {
      const lastModified = data.fields.LastModifiedDate.value;
      if (lastModified !== this.lastModified) {
        this.lastModified = lastModified;
        this.loadCard();
      }
    } else if (error) {
      this.error = errorMessage(error);
    }
  }

  get isRecordPage() {
    return !this.candidate;
  }

  get recordPageId() {
    return this.isRecordPage ? this.recordId : undefined;
  }

  async loadCard() {
    this.isLoading = true;
    try {
      this.loadedCandidate = await getCard({ candidateId: this.recordId });
      this.error = undefined;
    } catch (error) {
      this.error = errorMessage(error);
    } finally {
      this.isLoading = false;
    }
  }

  /** Display model built from whichever data source is in use. */
  get view() {
    const data = this.candidate || this.loadedCandidate;
    if (!data) {
      return undefined;
    }
    const level = scoreLevel(data.score);
    const hasYears =
      data.yearsExperience !== null && data.yearsExperience !== undefined;
    const skills = data.skills || [];
    const extraSkills = skills.length - MAX_SKILLS_SHOWN;
    const flags = FLAG_TYPES.filter((flag) => data[flag.countField] > 0).map(
      (flag) => ({
        type: flag.type,
        badgeClass: flag.badgeClass,
        label: `${data[flag.countField]} ${flag.type}`
      })
    );

    return {
      ...data,
      initials: initials(data.name),
      photoAlt: `Photo of ${data.name}`,
      subtitle: subtitle(data.currentTitle, data.country),
      years: hasYears
        ? `${data.yearsExperience} years of experience`
        : `Years of experience: ${NOT_FOUND_TEXT}`,
      yearsClass: hasYears
        ? "slds-text-body_small"
        : "slds-text-body_small missing",
      // A score belongs to an application, so it only shows in a job's applicant list.
      hasApplication: Boolean(data.applicantId),
      scoreLabel:
        data.score === null || data.score === undefined ? "-" : data.score,
      levelLabel: level.label,
      badgeClass: level.badgeClass,
      shownSkills: skills.slice(0, MAX_SKILLS_SHOWN),
      extraSkillsLabel: extraSkills > 0 ? `+${extraSkills}` : null,
      hasSkills: skills.length > 0,
      flags,
      hasFlags: flags.length > 0
    };
  }

  get photoButtonLabel() {
    return this.view?.photoUrl ? "Change photo" : "Add photo";
  }

  togglePhotoUpload() {
    this.isPhotoUploadOpen = !this.isPhotoUploadOpen;
  }

  async handlePhotoUploaded(event) {
    const [file] = event.detail.files;
    this.isPhotoUploadOpen = false;
    try {
      const result = await setPhoto({
        candidateId: this.recordId,
        contentVersionId: file.contentVersionId
      });
      if (result.error) {
        this.toast("Photo not saved", result.error, "error");
        return;
      }
      this.loadedCandidate = {
        ...this.loadedCandidate,
        photoUrl: result.photoUrl
      };
      this.toast(
        "Photo saved",
        `${this.loadedCandidate.name} now has a profile photo.`,
        "success"
      );
    } catch (error) {
      this.toast("Photo not saved", errorMessage(error), "error");
    }
  }

  openRecord(event) {
    event.preventDefault();
    this[NavigationMixin.Navigate]({
      type: "standard__recordPage",
      attributes: {
        recordId: event.currentTarget.dataset.id,
        actionName: "view"
      }
    });
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
}
