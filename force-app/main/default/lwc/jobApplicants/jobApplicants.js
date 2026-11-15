import { LightningElement, api } from "lwc";
import getApplicants from "@salesforce/apex/JobApplicantsController.getApplicants";
import { errorMessage } from "c/candidateUtils";

/** Applicants of a job as Candidate Cards, best score first. "Show more" loads the next page. */
export default class JobApplicants extends LightningElement {
  @api recordId;
  @api pageSize = 6;

  applicants = [];
  total = 0;
  error;
  isLoading = false;

  connectedCallback() {
    this.reload();
  }

  get title() {
    return `Applicants (${this.total})`;
  }

  get isEmpty() {
    return !this.isLoading && !this.error && this.applicants.length === 0;
  }

  get remaining() {
    return this.total - this.applicants.length;
  }

  get hasMore() {
    return this.remaining > 0;
  }

  get showMoreLabel() {
    return `Show more (${this.remaining} more)`;
  }

  async reload() {
    this.applicants = [];
    await this.loadPage();
  }

  async loadPage() {
    this.isLoading = true;
    try {
      const page = await getApplicants({
        jobId: this.recordId,
        pageSize: this.pageSize,
        offsetSize: this.applicants.length
      });
      this.applicants = [...this.applicants, ...page.applicants];
      this.total = page.total;
      this.error = undefined;
    } catch (error) {
      this.error = errorMessage(error);
    } finally {
      this.isLoading = false;
    }
  }

  handleShowMore() {
    this.loadPage();
  }

  handleRefresh() {
    this.reload();
  }
}
