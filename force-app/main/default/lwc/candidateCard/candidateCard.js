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

const MAX_SKILLS_SHOWN = 5; // list tile
const PAGE_SKILLS_SHOWN = 10; // record page, before "Show more"
const PHOTO_FORMATS = [".png", ".jpg", ".jpeg", ".gif", ".webp"];
// Display order: what needs the recruiter's attention first.
const FLAG_TYPES = [
  {
    type: "Conflict",
    key: "conflict",
    countField: "conflictCount",
    hint: "The CV and the record disagree: the record value is kept."
  },
  {
    type: "Missing",
    key: "missing",
    countField: "missingCount",
    hint: "Not found in the CV nor on the record."
  },
  {
    type: "Inferred",
    key: "inferred",
    countField: "inferredCount",
    hint: "Not stated in the CV, deduced from it: to confirm."
  }
];

/**
 * Candidate Card. Two ways to use it:
 *  - In a list: the parent passes the data in `candidate` (see jobApplicants). A compact tile: the
 *    name links to the candidate, the score and "View application" show when the data has an
 *    application, the first skills and the flag counts as pills.
 *  - On the Candidate record page: no `candidate` given, so the card loads itself from `recordId`,
 *    reloads when the record is saved, and offers the photo upload. A standard card with two
 *    collapsible sections: the skills (first 10, then "Show more"), and the data quality,
 *    collapsed by default (each Missing / Inferred / Conflict flag with its field and detail).
 */
export default class CandidateCard extends NavigationMixin(LightningElement) {
  @api recordId;
  @api candidate;

  loadedCandidate;
  error;
  isLoading = false;
  isPhotoUploadOpen = false;
  // Skills open, Data quality collapsed (its pills above already give the counts).
  openSections = ["skills"];
  showAllSkills = false;
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
    const extraSkills = skills.slice(MAX_SKILLS_SHOWN);
    const flagDetails = data.flags || [];
    const present = FLAG_TYPES.filter((flag) => data[flag.countField] > 0);
    const flagTotal = present.reduce(
      (total, flag) => total + data[flag.countField],
      0
    );

    return {
      ...data,
      initials: initials(data.name),
      photoAlt: `Photo of ${data.name}`,
      subtitle: subtitle(data.currentTitle, data.country),
      years: hasYears
        ? `${data.yearsExperience} years of experience`
        : `Years of experience: ${NOT_FOUND_TEXT}`,
      yearsClass: hasYears ? "years" : "years missing",
      // A score belongs to an application, so it only shows in a job's applicant list.
      hasApplication: Boolean(data.applicantId),
      scoreLabel:
        data.score === null || data.score === undefined ? "-" : data.score,
      scoreClass: `score score_${level.key}`,
      levelLabel: level.label,
      skills,
      shownSkills: skills.slice(0, MAX_SKILLS_SHOWN),
      extraSkillsLabel: extraSkills.length ? `+${extraSkills.length}` : null,
      extraSkillsTitle: extraSkills.join(", "),
      pageSkills: this.showAllSkills
        ? skills
        : skills.slice(0, PAGE_SKILLS_SHOWN),
      hasMoreSkills: skills.length > PAGE_SKILLS_SHOWN,
      moreSkillsLabel: this.showAllSkills
        ? "Show less"
        : `Show more (${skills.length - PAGE_SKILLS_SHOWN})`,
      hasSkills: skills.length > 0,
      skillsSectionLabel: `Skills (${skills.length})`,
      flagCounts: present.map((flag) => ({
        type: flag.type,
        pillClass: `pill pill_${flag.key}`,
        label: `${data[flag.countField]} ${flag.type}`
      })),
      flagGroups: present
        .map((flag) => ({
          type: flag.type,
          hint: flag.hint,
          pillClass: `pill pill_${flag.key}`,
          groupClass: `flag-group flag-group_${flag.key}`,
          items: flagDetails
            .filter((item) => item.type === flag.type)
            .map((item, index) => ({
              key: item.flagId || `${flag.type}-${index}`,
              field: item.field || "General",
              detail: item.detail
            }))
        }))
        .filter((group) => group.items.length > 0),
      hasFlags: flagTotal > 0,
      qualitySectionLabel: `Data quality (${flagTotal})`
    };
  }

  get photoButtonLabel() {
    return this.view?.photoUrl ? "Change photo" : "Add photo";
  }

  toggleAllSkills() {
    this.showAllSkills = !this.showAllSkills;
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
