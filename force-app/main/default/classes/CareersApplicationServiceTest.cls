@IsTest
private class CareersApplicationServiceTest {
  @TestSetup
  static void setup() {
    Job__c open = TestDataFactory.newJob('Salesforce Developer');
    open.Due_Date__c = Date.today().addDays(10);
    Job__c closed = TestDataFactory.newJob('Closed Job');
    closed.Due_Date__c = Date.today().addDays(-1);
    insert new List<Job__c>{ open, closed };
  }

  @IsTest
  static void createsCandidateApplicationAndFiles() {
    CareersApplicationService.Application application = validApplication();
    application.otherFiles = new List<CareersApplicationService.UploadedFile>{
      file('cover-letter.docx', 'letter')
    };

    Test.startTest();
    CareersApplicationService.Result result = new CareersApplicationService()
      .apply(application);
    Test.stopTest();

    Assert.isTrue(result.success, result.message);
    Candidate__c candidate = [
      SELECT Id, Name, Email__c, Phone__c, Country__c
      FROM Candidate__c
    ];
    Assert.areEqual('Nadia Kowalski', candidate.Name);
    Assert.areEqual(
      'nadia@test.cvreview',
      candidate.Email__c,
      'email is stored trimmed and lower case'
    );
    Assert.areEqual('+48 600 000 005', candidate.Phone__c);
    Assert.areEqual('Poland', candidate.Country__c);
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM Job_Applicant__c
        WHERE
          Candidate__c = :candidate.Id
          AND Job__c = :getJobId('Salesforce Developer')
      ]
    );
    List<ContentDocumentLink> links = [
      SELECT ContentDocument.Title
      FROM ContentDocumentLink
      WHERE LinkedEntityId = :candidate.Id
      ORDER BY ContentDocument.Title
    ];
    Assert.areEqual(2, links.size());
    Assert.areEqual('CV - Nadia Kowalski - cv', links[0].ContentDocument.Title);
    Assert.areEqual(
      'Document - Nadia Kowalski - cover-letter',
      links[1].ContentDocument.Title
    );
  }

  @IsTest
  static void reusesCandidateByEmailWithoutOverwritingIt() {
    Candidate__c existing = TestDataFactory.newCandidate('Nadia K.');
    existing.Email__c = 'nadia@test.cvreview';
    existing.Phone__c = '+48 1';
    insert existing;

    CareersApplicationService.Result result = new CareersApplicationService()
      .apply(validApplication());

    Assert.isTrue(result.success, result.message);
    Candidate__c candidate = [SELECT Name, Phone__c FROM Candidate__c];
    Assert.areEqual('Nadia K.', candidate.Name);
    Assert.areEqual('+48 1', candidate.Phone__c);
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Job_Applicant__c WHERE Candidate__c = :existing.Id]
    );
  }

  @IsTest
  static void refusesASecondApplicationToTheSameJob() {
    new CareersApplicationService().apply(validApplication());

    CareersApplicationService.Result result = new CareersApplicationService()
      .apply(validApplication());

    Assert.isFalse(result.success);
    Assert.isTrue(result.message.contains('already applied'), result.message);
    Assert.areEqual(1, [SELECT COUNT() FROM Job_Applicant__c]);
    Assert.areEqual(1, [SELECT COUNT() FROM ContentDocument]);
  }

  @IsTest
  static void refusesAClosedJob() {
    CareersApplicationService.Application application = validApplication();
    application.jobId = getJobId('Closed Job');

    assertRefused(application, 'This job is no longer open.');
  }

  @IsTest
  static void validatesTheForm() {
    CareersApplicationService.Application application = validApplication();
    application.fullName = ' ';
    assertRefused(application, 'Full name is required.');

    application = validApplication();
    application.email = 'not-an-email';
    assertRefused(application, 'Please enter a valid email address.');

    application = validApplication();
    application.phone = '1'.repeat(41);
    assertRefused(application, 'Phone must be at most 40 characters.');

    application = validApplication();
    application.consent = false;
    assertRefused(
      application,
      'Please accept that we store your data to process your application.'
    );

    application = validApplication();
    application.cv = null;
    assertRefused(application, 'Please upload your CV.');
  }

  @IsTest
  static void validatesTheFiles() {
    CareersApplicationService.Application application = validApplication();
    application.cv = file('cv.exe', 'x');
    assertRefused(application, 'Your CV must be a PDF or Word document.');

    application = validApplication();
    application.cv = new CareersApplicationService.UploadedFile();
    application.cv.fileName = 'cv.pdf';
    application.cv.base64 = 'A'
      .repeat(CareersApplicationService.MAX_CV_BYTES / 3 * 4 + 8);
    assertRefused(application, 'Your CV must be smaller than 2 MB.');

    application = validApplication();
    application.otherFiles = new List<CareersApplicationService.UploadedFile>{
      file('script.js', 'x')
    };
    assertRefused(
      application,
      'Other documents must be PDF, Word, PNG or JPG files.'
    );

    application = validApplication();
    application.otherFiles = new List<CareersApplicationService.UploadedFile>();
    for (Integer i = 0; i <= CareersApplicationService.MAX_OTHER_FILES; i++) {
      application.otherFiles.add(file('doc' + i + '.pdf', 'x'));
    }
    assertRefused(
      application,
      'You can add up to ' +
        CareersApplicationService.MAX_OTHER_FILES +
        ' other documents.'
    );
  }

  @IsTest
  static void hidesUnexpectedErrors() {
    CareersApplicationService.Application application = validApplication();
    application.cv.base64 = '***not base64***';

    CareersApplicationService.Result result = new CareersApplicationService()
      .apply(application);

    Assert.isFalse(result.success);
    Assert.areEqual(
      'Your application could not be sent. Please try again later.',
      result.message
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Candidate__c],
      'nothing is saved when the application fails'
    );
  }

  private static void assertRefused(
    CareersApplicationService.Application application,
    String expectedMessage
  ) {
    CareersApplicationService.Result result = new CareersApplicationService()
      .apply(application);
    Assert.isFalse(result.success);
    Assert.areEqual(expectedMessage, result.message);
    Assert.areEqual(0, [SELECT COUNT() FROM Candidate__c]);
  }

  private static CareersApplicationService.Application validApplication() {
    CareersApplicationService.Application application = new CareersApplicationService.Application();
    application.jobId = getJobId('Salesforce Developer');
    application.fullName = ' Nadia Kowalski ';
    application.email = ' Nadia@Test.CVReview ';
    application.phone = '+48 600 000 005';
    application.country = 'Poland';
    application.consent = true;
    application.cv = file('cv.pdf', 'my cv');
    return application;
  }

  private static CareersApplicationService.UploadedFile file(
    String fileName,
    String content
  ) {
    CareersApplicationService.UploadedFile file = new CareersApplicationService.UploadedFile();
    file.fileName = fileName;
    file.base64 = EncodingUtil.base64Encode(Blob.valueOf(content));
    return file;
  }

  private static Id getJobId(String name) {
    return [SELECT Id FROM Job__c WHERE Name = :name].Id;
  }
}
