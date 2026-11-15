import { LightningElement, api } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import CLOUDING_LOGO from "@salesforce/resourceUrl/CloudingLogo";

/** Careers portal header: Clouding AI logo (links to the job list) and the main navigation. */
export default class CareersHeader extends NavigationMixin(LightningElement) {
  /** API name of the page that holds the job list. */
  @api homePageApiName = "Home";

  logoUrl = CLOUDING_LOGO;

  goHome(event) {
    event.preventDefault();
    this[NavigationMixin.Navigate]({
      type: "comm__namedPage",
      attributes: { name: this.homePageApiName }
    });
  }
}
