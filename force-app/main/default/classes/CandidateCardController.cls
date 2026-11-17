/**
 * Data for the candidateCard LWC (compact Candidate Card), used on the Candidate record page and
 * in the job applicants list. buildCards() is the single place that builds the card data, so both
 * show the same thing.
 *
 * Runs with sharing and in user mode: the recruiter only gets what they are allowed to see.
 * Not cacheable: errors are logged with Nebula, which publishes an event (not allowed in a
 * cacheable method). The LWC reloads the card itself when the record changes.
 */
public with sharing class CandidateCardController {
  public class Card {
    @AuraEnabled
    public Id candidateId;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String currentTitle;
    @AuraEnabled
    public String country;
    @AuraEnabled
    public Decimal yearsExperience;
    @AuraEnabled
    public String photoUrl;
    @AuraEnabled
    public List<String> skills = new List<String>();
    @AuraEnabled
    public Integer missingCount = 0;
    @AuraEnabled
    public Integer inferredCount = 0;
    @AuraEnabled
    public Integer conflictCount = 0;
    /** The flags themselves, shown in the card's Data quality section. */
    @AuraEnabled
    public List<Flag> flags = new List<Flag>();
    /** Set only in a job's applicant list: a score belongs to one application, not to the candidate. */
    @AuraEnabled
    public Id applicantId;
    @AuraEnabled
    public Decimal score;
  }

  /** A Missing / Inferred / Conflict flag left by the CV extraction. */
  public class Flag {
    @AuraEnabled
    public Id flagId;
    @AuraEnabled
    public String type;
    @AuraEnabled
    public String field;
    @AuraEnabled
    public String detail;
  }

  /** Result of a photo upload: the new photo URL, or an error to show (the upload is then removed). */
  public class PhotoResult {
    @AuraEnabled
    public String photoUrl;
    @AuraEnabled
    public String error;
  }

  @AuraEnabled
  public static Card getCard(Id candidateId) {
    try {
      Map<Id, Card> cards = buildCards(new Set<Id>{ candidateId });
      if (!cards.containsKey(candidateId)) {
        throw auraError('Candidate not found or not accessible.');
      }
      return cards.get(candidateId);
    } catch (AuraHandledException ex) {
      throw ex;
    } catch (Exception ex) {
      throw logAndWrap(
        'Loading the card failed for candidate ' + candidateId,
        ex
      );
    }
  }

  /** Card data for each accessible candidate, by candidate Id. 3 queries whatever the number of candidates. */
  public static Map<Id, Card> buildCards(Set<Id> candidateIds) {
    Map<Id, Card> cards = new Map<Id, Card>();
    for (Candidate__c candidate : [
      SELECT
        Id,
        Name,
        Current_Title__c,
        Country__c,
        Years_Experience__c,
        Photo_Version_Id__c
      FROM Candidate__c
      WHERE Id IN :candidateIds
      WITH USER_MODE
    ]) {
      Card card = new Card();
      card.candidateId = candidate.Id;
      card.name = candidate.Name;
      card.currentTitle = candidate.Current_Title__c;
      card.country = candidate.Country__c;
      card.yearsExperience = candidate.Years_Experience__c;
      card.photoUrl = photoUrl(candidate.Photo_Version_Id__c);
      cards.put(candidate.Id, card);
    }
    if (cards.isEmpty()) {
      return cards;
    }

    Set<Id> foundIds = cards.keySet();
    for (Candidate_Skill__c candidateSkill : [
      SELECT Candidate__c, Skill__r.Name
      FROM Candidate_Skill__c
      WHERE Candidate__c IN :foundIds
      WITH USER_MODE
      ORDER BY Skill__r.Name
    ]) {
      cards.get(candidateSkill.Candidate__c)
        .skills.add(candidateSkill.Skill__r.Name);
    }

    for (Extraction_Flag__c row : [
      SELECT Id, Candidate__c, Type__c, Field__c, Detail__c
      FROM Extraction_Flag__c
      WHERE Candidate__c IN :foundIds
      WITH USER_MODE
      ORDER BY Type__c, Field__c
    ]) {
      Card card = cards.get(row.Candidate__c);
      Flag flag = new Flag();
      flag.flagId = row.Id;
      flag.type = row.Type__c;
      flag.field = row.Field__c;
      flag.detail = row.Detail__c;
      card.flags.add(flag);
      if (row.Type__c == Constants.FLAG_MISSING) {
        card.missingCount++;
      } else if (row.Type__c == Constants.FLAG_INFERRED) {
        card.inferredCount++;
      } else if (row.Type__c == Constants.FLAG_CONFLICT) {
        card.conflictCount++;
      }
    }
    return cards;
  }

  /**
   * Saves the uploaded image as the candidate's photo. The file must be an image already
   * linked to the candidate (lightning-file-upload links it). A non-image upload is deleted and
   * returned as an error (not thrown, so the delete isn't rolled back).
   * The previous photo file is deleted when the user is allowed to.
   */
  @AuraEnabled
  public static PhotoResult setPhoto(Id candidateId, Id contentVersionId) {
    try {
      List<ContentVersion> versions = [
        SELECT Id, ContentDocumentId, FileType
        FROM ContentVersion
        WHERE Id = :contentVersionId
        WITH USER_MODE
      ];
      if (versions.isEmpty()) {
        throw auraError('The uploaded file was not found.');
      }
      ContentVersion version = versions[0];

      Integer links = [
        SELECT COUNT()
        FROM ContentDocumentLink
        WHERE
          ContentDocumentId = :version.ContentDocumentId
          AND LinkedEntityId = :candidateId
        WITH USER_MODE
      ];
      if (links == 0) {
        throw auraError('The file is not attached to this candidate.');
      }
      PhotoResult result = new PhotoResult();
      if (
        !Constants.IMAGE_EXTENSIONS.contains(version.FileType?.toLowerCase())
      ) {
        delete as user new ContentDocument(Id = version.ContentDocumentId);
        result.error = 'The photo must be a PNG, JPG, GIF or WEBP image.';
        return result;
      }

      Candidate__c candidate = [
        SELECT Id, Photo_Version_Id__c
        FROM Candidate__c
        WHERE Id = :candidateId
        WITH USER_MODE
      ];
      Id previousVersionId = candidate.Photo_Version_Id__c;
      update as user new Candidate__c(
        Id = candidateId,
        Photo_Version_Id__c = version.Id
      );
      deletePreviousPhoto(previousVersionId, version.ContentDocumentId);

      Logger.info('Photo set for candidate ' + candidateId)
        .addTag(Constants.LOG_TAG_CANDIDATE_CARD);
      Logger.saveLog();
      result.photoUrl = photoUrl(version.Id);
      return result;
    } catch (AuraHandledException ex) {
      throw ex;
    } catch (Exception ex) {
      throw logAndWrap(
        'Saving the photo failed for candidate ' + candidateId,
        ex
      );
    }
  }

  /** URL that renders a ContentVersion image for internal users. Null when there is no photo. */
  public static String photoUrl(String contentVersionId) {
    return String.isBlank(contentVersionId)
      ? null
      : '/sfc/servlet.shepherd/version/download/' + contentVersionId;
  }

  /** Best effort: the user may not own the old file. Failures are logged, not shown. */
  private static void deletePreviousPhoto(
    Id previousVersionId,
    Id newDocumentId
  ) {
    if (previousVersionId == null) {
      return;
    }
    List<ContentVersion> previous = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :previousVersionId
      WITH USER_MODE
    ];
    if (previous.isEmpty() || previous[0].ContentDocumentId == newDocumentId) {
      return;
    }
    Database.DeleteResult result = Database.delete(
      new ContentDocument(Id = previous[0].ContentDocumentId),
      false,
      AccessLevel.USER_MODE
    );
    if (!result.isSuccess()) {
      Logger.warn(
          'Previous photo not deleted: ' + result.getErrors()[0].getMessage()
        )
        .addTag(Constants.LOG_TAG_CANDIDATE_CARD);
    }
  }

  @TestVisible
  private static AuraHandledException logAndWrap(String message, Exception ex) {
    Logger.error(message)
      .setExceptionDetails(ex)
      .addTag(Constants.LOG_TAG_CANDIDATE_CARD);
    Logger.saveLog();
    return auraError(message + ': ' + ex.getMessage());
  }

  /** setMessage makes the text readable in Apex (tests, logs), not only in the LWC. */
  @TestVisible
  private static AuraHandledException auraError(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    return error;
  }
}
