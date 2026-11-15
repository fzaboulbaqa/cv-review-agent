import { LightningElement, api } from "lwc";
import apply from "@salesforce/apex/CareersController.apply";
import { errorMessage, extensionOf, readAsBase64 } from "c/careersUtils";

// Same rules as CareersApplicationService: checked here for a quick answer, enforced on the server.
const MB = 1024 * 1024;
const MAX_CV_BYTES = 2 * MB;
const MAX_TOTAL_BYTES = 3 * MB;
const MAX_OTHER_FILES = 3;
const CV_EXTENSIONS = ["pdf", "doc", "docx"];
const OTHER_EXTENSIONS = ["pdf", "doc", "docx", "png", "jpg", "jpeg"];
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * Application form for one job: contact details, CV (required), up to 3 other documents and
 * consent. Files are sent as base64 to Apex: the guest user has no record to attach them to yet.
 */
export default class CareersApplyForm extends LightningElement {
  @api jobId;
  @api jobTitle;

  fullName = "";
  email = "";
  phone = "";
  country = "";
  consent = false;
  cvFile;
  otherFiles = [];

  error;
  successMessage;
  isSubmitting = false;

  cvAccept = CV_EXTENSIONS.map((ext) => `.${ext}`).join(",");
  otherAccept = OTHER_EXTENSIONS.map((ext) => `.${ext}`).join(",");

  get title() {
    return `Apply for ${this.jobTitle}`;
  }

  get cvName() {
    return this.cvFile
      ? `${this.cvFile.name} (${this.formatSize(this.cvFile.size)})`
      : "No file chosen";
  }

  get otherFileItems() {
    return this.otherFiles.map((file, index) => ({
      key: `${index}-${file.name}`,
      index,
      label: `${file.name} (${this.formatSize(file.size)})`
    }));
  }

  get hasOtherFiles() {
    return this.otherFiles.length > 0;
  }

  get canAddOtherFiles() {
    return this.otherFiles.length < MAX_OTHER_FILES;
  }

  get submitLabel() {
    return this.isSubmitting ? "Sending..." : "Submit application";
  }

  // ---------- Inputs ----------

  handleInput(event) {
    const field = event.target.dataset.field;
    this[field] =
      event.target.type === "checkbox"
        ? event.target.checked
        : event.target.value;
  }

  handleCv(event) {
    const [file] = event.target.files;
    event.target.value = null;
    if (!file) {
      return;
    }
    const problem = this.checkFile(
      file,
      CV_EXTENSIONS,
      "Your CV must be a PDF or Word document."
    );
    if (problem) {
      this.error = problem;
      return;
    }
    if (file.size > MAX_CV_BYTES) {
      this.error = "Your CV must be smaller than 2 MB.";
      return;
    }
    this.error = undefined;
    this.cvFile = file;
  }

  handleOtherFiles(event) {
    const files = [...event.target.files];
    event.target.value = null;
    const all = [...this.otherFiles, ...files];
    if (all.length > MAX_OTHER_FILES) {
      this.error = `You can add up to ${MAX_OTHER_FILES} other documents.`;
      return;
    }
    for (const file of files) {
      const problem = this.checkFile(
        file,
        OTHER_EXTENSIONS,
        "Other documents must be PDF, Word, PNG or JPG files."
      );
      if (problem) {
        this.error = problem;
        return;
      }
    }
    this.error = undefined;
    this.otherFiles = all;
  }

  handleRemoveFile(event) {
    const index = Number(event.currentTarget.dataset.index);
    this.otherFiles = this.otherFiles.filter((_, i) => i !== index);
  }

  handleCancel() {
    this.dispatchEvent(new CustomEvent("cancel"));
  }

  // ---------- Submit ----------

  async handleSubmit(event) {
    event.preventDefault();
    if (!this.validate()) {
      return;
    }
    this.isSubmitting = true;
    this.error = undefined;
    try {
      const result = await apply({
        application: await this.buildApplication()
      });
      if (result.success) {
        this.successMessage = result.message;
      } else {
        this.error = result.message;
      }
    } catch (error) {
      this.error = errorMessage(error);
    } finally {
      this.isSubmitting = false;
    }
  }

  validate() {
    // Shows the messages under the fields; the decision is made by the checks below.
    this.template
      .querySelectorAll("lightning-input")
      .forEach((input) => input.reportValidity());
    if (!this.fullName.trim() || !this.email.trim()) {
      this.error = "Please enter your full name and email.";
      return false;
    }
    if (!EMAIL_PATTERN.test(this.email.trim())) {
      this.error = "Please enter a valid email address.";
      return false;
    }
    if (!this.cvFile) {
      this.error = "Please upload your CV.";
      return false;
    }
    const total = [this.cvFile, ...this.otherFiles].reduce(
      (sum, file) => sum + file.size,
      0
    );
    if (total > MAX_TOTAL_BYTES) {
      this.error = "All files together must be smaller than 3 MB.";
      return false;
    }
    if (!this.consent) {
      this.error =
        "Please accept that we store your data to process your application.";
      return false;
    }
    return true;
  }

  async buildApplication() {
    const toUpload = async (file) => ({
      fileName: file.name,
      base64: await readAsBase64(file)
    });
    return {
      jobId: this.jobId,
      fullName: this.fullName,
      email: this.email,
      phone: this.phone,
      country: this.country,
      consent: this.consent,
      cv: await toUpload(this.cvFile),
      otherFiles: await Promise.all(this.otherFiles.map(toUpload))
    };
  }

  // ---------- Helpers ----------

  checkFile(file, extensions, message) {
    return extensions.includes(extensionOf(file.name)) ? null : message;
  }

  formatSize(bytes) {
    return bytes < MB
      ? `${Math.max(1, Math.round(bytes / 1024))} KB`
      : `${(bytes / MB).toFixed(1)} MB`;
  }
}
