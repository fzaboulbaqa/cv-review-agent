@IsTest
private class CandidateCardControllerTest {
  @TestSetup
  static void setup() {
    Candidate__c candidate = TestDataFactory.newCandidate('Test Candidate');
    candidate.Current_Title__c = 'Salesforce Developer';
    candidate.Years_Experience__c = 4;
    insert candidate;
    TestDataFactory.addCandidateSkills(
      candidate.Id,
      new List<String>{ 'LWC', 'Apex' }
    );
    insert new List<Extraction_Flag__c>{
      TestDataFactory.newFlag(
        candidate.Id,
        Constants.FLAG_MISSING,
        'Phone',
        'No phone.'
      ),
      TestDataFactory.newFlag(
        candidate.Id,
        Constants.FLAG_INFERRED,
        'Skills',
        'LWC inferred.'
      )
    };
    Job__c job = TestDataFactory.createJob('Salesforce Developer');
    TestDataFactory.createApplicant(job.Id, candidate.Id, 75);
  }

  @IsTest
  static void returnsTheCompactCard() {
    Candidate__c candidate = getCandidate();

    Test.startTest();
    CandidateCardController.Card card = CandidateCardController.getCard(
      candidate.Id
    );
    Test.stopTest();

    Assert.areEqual(candidate.Id, card.candidateId);
    Assert.areEqual('Test Candidate', card.name);
    Assert.areEqual('Salesforce Developer', card.currentTitle);
    Assert.areEqual(4, card.yearsExperience);
    Assert.isNull(card.photoUrl);
    Assert.areEqual(new List<String>{ 'Apex', 'LWC' }, card.skills);
    Assert.areEqual(1, card.missingCount);
    Assert.areEqual(1, card.inferredCount);
    Assert.areEqual(0, card.conflictCount);
    // The score belongs to an application, so the candidate's own card has none.
    Assert.isNull(card.applicantId);
    Assert.isNull(card.score);
  }

  @IsTest
  static void returnsThePhotoUrl() {
    Candidate__c candidate = getCandidate();
    ContentVersion photo = insertFile(candidate.Id, 'photo.png');
    update new Candidate__c(Id = candidate.Id, Photo_Version_Id__c = photo.Id);

    CandidateCardController.Card card = CandidateCardController.getCard(
      candidate.Id
    );

    Assert.areEqual(
      '/sfc/servlet.shepherd/version/download/' + photo.Id,
      card.photoUrl
    );
  }

  @IsTest
  static void buildsNothingForNoCandidates() {
    Assert.isTrue(CandidateCardController.buildCards(new Set<Id>()).isEmpty());
  }

  @IsTest
  static void wrapsUnexpectedErrors() {
    AuraHandledException error = CandidateCardController.logAndWrap(
      'Loading failed',
      new DmlException('boom')
    );

    Assert.areEqual('Loading failed: boom', error.getMessage());
  }

  @IsTest
  static void unknownCandidateFails() {
    Candidate__c candidate = getCandidate();
    delete candidate;

    try {
      CandidateCardController.getCard(candidate.Id);
      Assert.fail('Expected an AuraHandledException');
    } catch (AuraHandledException ex) {
      Assert.isTrue(ex.getMessage().contains('not found'), ex.getMessage());
    }
  }

  @IsTest
  static void setsPhotoAndDeletesThePreviousOne() {
    Candidate__c candidate = getCandidate();
    ContentVersion oldPhoto = insertFile(candidate.Id, 'old.png');
    update new Candidate__c(
      Id = candidate.Id,
      Photo_Version_Id__c = oldPhoto.Id
    );
    ContentVersion newPhoto = insertFile(candidate.Id, 'new.jpg');

    Test.startTest();
    CandidateCardController.PhotoResult result = CandidateCardController.setPhoto(
      candidate.Id,
      newPhoto.Id
    );
    Test.stopTest();

    Assert.isNull(result.error);
    Assert.areEqual(
      CandidateCardController.photoUrl(newPhoto.Id),
      result.photoUrl
    );
    Assert.areEqual(newPhoto.Id, getCandidate().Photo_Version_Id__c);
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM ContentDocument
        WHERE Id = :oldPhoto.ContentDocumentId
      ]
    );
  }

  @IsTest
  static void rejectsAndDeletesNonImage() {
    Candidate__c candidate = getCandidate();
    ContentVersion pdf = insertFile(candidate.Id, 'not-a-photo.pdf');

    CandidateCardController.PhotoResult result = CandidateCardController.setPhoto(
      candidate.Id,
      pdf.Id
    );

    Assert.isNotNull(result.error);
    Assert.isNull(result.photoUrl);
    Assert.isNull(getCandidate().Photo_Version_Id__c);
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM ContentDocument WHERE Id = :pdf.ContentDocumentId]
    );
  }

  @IsTest
  static void rejectsFileOfAnotherRecord() {
    Candidate__c candidate = getCandidate();
    Candidate__c other = TestDataFactory.createCandidate('Other');
    ContentVersion photo = insertFile(other.Id, 'photo.png');

    try {
      CandidateCardController.setPhoto(candidate.Id, photo.Id);
      Assert.fail('Expected an AuraHandledException');
    } catch (AuraHandledException ex) {
      Assert.isTrue(ex.getMessage().contains('not attached'), ex.getMessage());
    }
    Assert.isNull(getCandidate().Photo_Version_Id__c);
  }

  private static Candidate__c getCandidate() {
    return [
      SELECT Id, Photo_Version_Id__c
      FROM Candidate__c
      WHERE Name = 'Test Candidate'
    ];
  }

  private static ContentVersion insertFile(Id recordId, String fileName) {
    return TestDataFactory.createFile(recordId, fileName, 'test content');
  }
}
