import { LightningElement, api } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import searchJobs from "@salesforce/apex/CareersController.searchJobs";
import getFilterOptions from "@salesforce/apex/CareersController.getFilterOptions";
import { dueDateLabel, errorMessage, experienceTag } from "c/careersUtils";

const KEYWORD_DELAY_MS = 350;
const MAX_PAGE_LINKS = 7;

/**
 * Careers portal job list: filter panel (keyword, location, skills, years of experience),
 * result count, numbered pagination and job cards. A card opens the Job Detail page.
 */
export default class CareersJobList extends NavigationMixin(LightningElement) {
  /** API name of the Experience Builder page that shows one job. */
  @api detailPageApiName = "Job_Detail__c";

  keyword = "";
  selectedLocations = [];
  selectedSkills = [];
  years;
  pageNumber = 1;

  options = { locations: [], skills: [] };
  openSections = { location: false, skills: false, experience: false };
  result = { total: 0, pageSize: 10, jobs: [] };
  error;
  isLoading = false;
  keywordTimer;
  requestId = 0;

  connectedCallback() {
    this.loadOptions();
    this.search();
  }

  // ---------- Data ----------

  async loadOptions() {
    try {
      this.options = await getFilterOptions();
    } catch {
      // The list still works without the filter values.
      this.options = { locations: [], skills: [] };
    }
  }

  async search() {
    // Each search gets a number, so an older, slower answer can be recognized and ignored.
    this.requestId = this.requestId + 1;
    const requestId = this.requestId;
    this.isLoading = true;
    try {
      const result = await searchJobs({
        keyword: this.keyword,
        locations: this.selectedLocations,
        skills: this.selectedSkills,
        years: this.years,
        pageNumber: this.pageNumber
      });
      // Ignore answers to older searches (fast typing).
      if (requestId === this.requestId) {
        this.result = result;
        this.error = undefined;
      }
    } catch (error) {
      if (requestId === this.requestId) {
        this.error = errorMessage(error);
      }
    } finally {
      if (requestId === this.requestId) {
        this.isLoading = false;
      }
    }
  }

  // ---------- Filters ----------

  handleKeyword(event) {
    this.keyword = event.target.value;
    clearTimeout(this.keywordTimer);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.keywordTimer = setTimeout(() => this.applyFilters(), KEYWORD_DELAY_MS);
  }

  handleToggleSection(event) {
    const section = event.currentTarget.dataset.section;
    // Copy the object so the template sees the change.
    const openSections = { ...this.openSections };
    openSections[section] = !openSections[section];
    this.openSections = openSections;
  }

  handleLocation(event) {
    this.selectedLocations = this.toggle(
      this.selectedLocations,
      event.target.value,
      event.target.checked
    );
    this.applyFilters();
  }

  handleSkill(event) {
    this.selectedSkills = this.toggle(
      this.selectedSkills,
      event.target.value,
      event.target.checked
    );
    this.applyFilters();
  }

  handleYears(event) {
    const value = event.target.value;
    if (value === "" || value === null) {
      this.years = undefined;
    } else {
      this.years = Number(value);
    }
    this.applyFilters();
  }

  handleClear() {
    this.keyword = "";
    this.selectedLocations = [];
    this.selectedSkills = [];
    this.years = undefined;
    this.applyFilters();
  }

  applyFilters() {
    this.pageNumber = 1;
    this.search();
  }

  /** Adds the value to the list when checked, removes it otherwise (returns a new list). */
  toggle(values, value, checked) {
    if (checked) {
      return [...values, value];
    }
    return values.filter((item) => item !== value);
  }

  get locationOptions() {
    return this.options.locations.map((value) => ({
      value,
      key: `location-${value}`,
      checked: this.selectedLocations.includes(value)
    }));
  }

  get skillOptions() {
    return this.options.skills.map((value) => ({
      value,
      key: `skill-${value}`,
      checked: this.selectedSkills.includes(value)
    }));
  }

  get hasLocations() {
    return this.options.locations.length > 0;
  }

  get hasSkills() {
    return this.options.skills.length > 0;
  }

  get sections() {
    let experienceCount = "";
    if (this.years !== undefined) {
      experienceCount = "(1)";
    }
    return {
      location: {
        open: this.openSections.location,
        icon: this.chevron(this.openSections.location),
        count: this.countLabel(this.selectedLocations)
      },
      skills: {
        open: this.openSections.skills,
        icon: this.chevron(this.openSections.skills),
        count: this.countLabel(this.selectedSkills)
      },
      experience: {
        open: this.openSections.experience,
        icon: this.chevron(this.openSections.experience),
        count: experienceCount
      }
    };
  }

  chevron(open) {
    if (open) {
      return "utility:chevronup";
    }
    return "utility:chevrondown";
  }

  /** "(2)" when 2 values are selected, "" when none. */
  countLabel(values) {
    if (values.length > 0) {
      return `(${values.length})`;
    }
    return "";
  }

  get hasActiveFilters() {
    return Boolean(
      this.keyword ||
      this.selectedLocations.length ||
      this.selectedSkills.length ||
      this.years !== undefined
    );
  }

  // ---------- Results ----------

  get resultLabel() {
    const total = this.result.total;
    if (total === 1) {
      return "1 Result";
    }
    return `${total} Results`;
  }

  get jobs() {
    return this.result.jobs.map((job) => {
      return {
        ...job,
        tag: experienceTag(job.minYears),
        location: job.location || "Location not specified",
        dueLabel: dueDateLabel(job.dueDate)
      };
    });
  }

  get isEmpty() {
    return !this.isLoading && !this.error && this.result.jobs.length === 0;
  }

  openJob(event) {
    event.preventDefault();
    this[NavigationMixin.Navigate]({
      type: "comm__namedPage",
      attributes: { name: this.detailPageApiName },
      state: { jobId: event.currentTarget.dataset.id }
    });
  }

  // ---------- Pagination ----------

  get totalPages() {
    const pageCount = Math.ceil(this.result.total / this.result.pageSize);
    // Always at least one page, even with no results.
    return Math.max(1, pageCount);
  }

  get hasPages() {
    return this.totalPages > 1;
  }

  /** 1 2 3 ... 80 style links, always with the first, last and current page. */
  get pages() {
    const total = this.totalPages;
    const current = this.pageNumber;
    // Step 1: which page numbers to show.
    let numbers = [];
    if (total <= MAX_PAGE_LINKS) {
      for (let page = 1; page <= total; page++) {
        numbers.push(page);
      }
    } else if (current <= 3) {
      numbers = [1, 2, 3, 4, total];
    } else if (current >= total - 2) {
      numbers = [1, total - 3, total - 2, total - 1, total];
    } else {
      numbers = [1, current - 1, current, current + 1, total];
    }
    // Step 2: build the links, with a "..." gap where numbers are skipped.
    const items = [];
    for (let index = 0; index < numbers.length; index++) {
      const page = numbers[index];
      const previousPage = numbers[index - 1];
      if (index > 0 && page - previousPage > 1) {
        items.push({ key: `gap-${page}`, isGap: true });
      }
      const isCurrent = page === current;
      let className = "page";
      let ariaCurrent = null;
      if (isCurrent) {
        className = "page current";
        ariaCurrent = "page";
      }
      items.push({
        key: `page-${page}`,
        page,
        isGap: false,
        className,
        ariaCurrent
      });
    }
    return items;
  }

  get isFirstPage() {
    return this.pageNumber <= 1;
  }

  get isLastPage() {
    return this.pageNumber >= this.totalPages;
  }

  handlePage(event) {
    this.goTo(Number(event.currentTarget.dataset.page));
  }

  handlePrevious() {
    this.goTo(this.pageNumber - 1);
  }

  handleNext() {
    this.goTo(this.pageNumber + 1);
  }

  goTo(page) {
    if (page < 1 || page > this.totalPages || page === this.pageNumber) {
      return;
    }
    this.pageNumber = page;
    this.search();
    const results = this.template.querySelector(".results");
    if (results && results.scrollIntoView) {
      results.scrollIntoView({ behavior: "smooth", block: "start" });
    }
  }
}
