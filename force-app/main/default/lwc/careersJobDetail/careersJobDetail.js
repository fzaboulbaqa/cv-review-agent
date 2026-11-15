import { LightningElement, api, wire } from "lwc";
import { CurrentPageReference, NavigationMixin } from "lightning/navigation";
import getJob from "@salesforce/apex/CareersController.getJob";
import { dueDateLabel, errorMessage, experienceTag } from "c/careersUtils";

/**
 * Careers portal job detail: reads ?jobId= from the URL, shows the job and its skills,
 * and opens the application form under it on "Apply now".
 */
export default class CareersJobDetail extends NavigationMixin(
  LightningElement
) {
  /** API name of the page that holds the job list (to go back). */
  @api listPageApiName = "Home";

  jobId;
  detail;
  error;
  isLoading = false;
  isApplying = false;

  @wire(CurrentPageReference)
  handlePageReference(pageReference) {
    const jobId = pageReference?.state?.jobId;
    if (jobId && jobId !== this.jobId) {
      this.jobId = jobId;
      this.isApplying = false;
      this.loadJob();
    } else if (!jobId && pageReference) {
      this.error = "No job selected.";
    }
  }

  async loadJob() {
    this.isLoading = true;
    try {
      this.detail = await getJob({ jobId: this.jobId });
      this.error = undefined;
    } catch (error) {
      this.detail = undefined;
      this.error = errorMessage(error);
    } finally {
      this.isLoading = false;
    }
  }

  get job() {
    const { job } = this.detail;
    return {
      ...job,
      tag: experienceTag(job.minYears),
      location: job.location || "Location not specified",
      dueLabel: dueDateLabel(job.dueDate),
      experienceLabel:
        job.minYears === null ||
        job.minYears === undefined ||
        job.minYears === 0
          ? "No minimum experience"
          : `At least ${job.minYears} years of experience`
    };
  }

  get description() {
    return this.detail.description || "No description available yet.";
  }

  get hasMustHave() {
    return this.detail.mustHaveSkills.length > 0;
  }

  get hasNiceToHave() {
    return this.detail.niceToHaveSkills.length > 0;
  }

  get showApplyButton() {
    return !this.isApplying;
  }

  handleApply() {
    this.isApplying = true;
    // Wait for the form to render, then bring it into view.
    Promise.resolve().then(() => {
      this.template
        .querySelector("c-careers-apply-form")
        ?.scrollIntoView?.({ behavior: "smooth", block: "start" });
    });
  }

  handleCancelApply() {
    this.isApplying = false;
  }

  handleBack(event) {
    event.preventDefault();
    this[NavigationMixin.Navigate]({
      type: "comm__namedPage",
      attributes: { name: this.listPageApiName }
    });
  }
}
