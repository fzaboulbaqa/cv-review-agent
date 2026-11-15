/**
 * Data for the jobApplicants LWC: the applicants of a job as Candidate Cards, best score first,
 * one page at a time ("Show more" asks for the next page).
 * The card data comes from CandidateCardController.buildCards, so the cards match the one on the
 * Candidate record page. This class only adds the application (Id and score).
 *
 * Runs with sharing and in user mode. Not cacheable, for the same reason as CandidateCardController.
 */
public with sharing class JobApplicantsController {
  @TestVisible
  private static final Integer MAX_PAGE_SIZE = 50;
  private static final Integer MAX_OFFSET = 2000; // SOQL OFFSET limit
  private static final String LOG_TAG = 'JobApplicants';

  public class ApplicantPage {
    @AuraEnabled
    public Integer total;
    @AuraEnabled
    public List<CandidateCardController.Card> applicants = new List<CandidateCardController.Card>();
  }

  @AuraEnabled
  public static ApplicantPage getApplicants(
    Id jobId,
    Integer pageSize,
    Integer offsetSize
  ) {
    Integer safePageSize = pageSize == null ||
      pageSize < 1
      ? 1
      : Math.min(pageSize, MAX_PAGE_SIZE);
    Integer safeOffset = offsetSize == null ||
      offsetSize < 0
      ? 0
      : Math.min(offsetSize, MAX_OFFSET);
    try {
      ApplicantPage page = new ApplicantPage();
      page.total = [
        SELECT COUNT()
        FROM Job_Applicant__c
        WHERE Job__c = :jobId
        WITH USER_MODE
      ];

      List<Job_Applicant__c> applicants = [
        SELECT Id, Score__c, Candidate__c
        FROM Job_Applicant__c
        WHERE Job__c = :jobId
        WITH USER_MODE
        ORDER BY Score__c DESC NULLS LAST, Candidate__r.Name ASC, Id ASC
        LIMIT :safePageSize
        OFFSET :safeOffset
      ];

      Set<Id> candidateIds = new Set<Id>();
      for (Job_Applicant__c applicant : applicants) {
        candidateIds.add(applicant.Candidate__c);
      }
      // A candidate applies once per job, so each card belongs to exactly one application.
      Map<Id, CandidateCardController.Card> cards = CandidateCardController.buildCards(
        candidateIds
      );
      for (Job_Applicant__c applicant : applicants) {
        CandidateCardController.Card card = cards.get(applicant.Candidate__c);
        if (card == null) {
          continue;
        }
        card.applicantId = applicant.Id;
        card.score = applicant.Score__c;
        page.applicants.add(card);
      }
      return page;
    } catch (Exception ex) {
      Logger.error('Loading applicants failed for job ' + jobId)
        .setExceptionDetails(ex)
        .addTag(LOG_TAG);
      Logger.saveLog();
      String message = 'Loading applicants failed: ' + ex.getMessage();
      AuraHandledException wrapped = new AuraHandledException(message);
      wrapped.setMessage(message);
      throw wrapped;
    }
  }
}
