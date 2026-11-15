/**
 * Creates an application submitted from the careers portal.
 *
 * Runs WITHOUT sharing on purpose: the guest user has no create access on any object, so this
 * class is the only way in. In exchange it stays narrow:
 *  - accepts a fixed set of fields and validates every one (length, format, file type and size),
 *  - only creates records, never updates an existing candidate (an email typed by someone else
 *    must not overwrite that candidate's data),
 *  - returns only a success flag and a message: no Ids, no candidate data.
 *
 * Same email = same candidate: the new application and files are added to the existing record.
 * Applying twice to the same job is refused with a friendly message.
 */
public without sharing class CareersApplicationService {
  @TestVisible
  private static final Integer MAX_CV_BYTES = 2 * 1024 * 1024;
  @TestVisible
  private static final Integer MAX_TOTAL_BYTES = 3 * 1024 * 1024;
  @TestVisible
  private static final Integer MAX_OTHER_FILES = 3;
  private static final Set<String> CV_EXTENSIONS = new Set<String>{
    'pdf',
    'doc',
    'docx'
  };
  private static final Set<String> OTHER_EXTENSIONS = new Set<String>{
    'pdf',
    'doc',
    'docx',
    'png',
    'jpg',
    'jpeg'
  };
  private static final Pattern EMAIL_PATTERN = Pattern.compile(
    '^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$'
  );
  private static final String LOG_TAG = 'Careers';

  public class Application {
    @AuraEnabled
    public Id jobId { get; set; }
    @AuraEnabled
    public String fullName { get; set; }
    @AuraEnabled
    public String email { get; set; }
    @AuraEnabled
    public String phone { get; set; }
    @AuraEnabled
    public String country { get; set; }
    @AuraEnabled
    public Boolean consent { get; set; }
    @AuraEnabled
    public UploadedFile cv { get; set; }
    @AuraEnabled
    public List<UploadedFile> otherFiles { get; set; }
  }

  public class UploadedFile {
    @AuraEnabled
    public String fileName { get; set; }
    @AuraEnabled
    public String base64 { get; set; }
  }

  public class Result {
    @AuraEnabled
    public Boolean success = false;
    @AuraEnabled
    public String message;
  }

  private class ValidationException extends Exception {
  }

  public Result apply(Application application) {
    Result result = new Result();
    Savepoint savepoint = Database.setSavepoint();
    try {
      validate(application);
      Job__c job = getOpenJob(application.jobId);
      String email = application.email.trim().toLowerCase();

      Candidate__c candidate = findCandidate(email);
      if (candidate == null) {
        candidate = new Candidate__c(
          Name = application.fullName.trim(),
          Email__c = email,
          Phone__c = trimToNull(application.phone),
          Country__c = trimToNull(application.country)
        );
        insert candidate;
      } else if (hasApplied(candidate.Id, job.Id)) {
        result.message = 'You have already applied to this job. We will contact you if your profile matches.';
        return result;
      }

      insert new Job_Applicant__c(Candidate__c = candidate.Id, Job__c = job.Id);
      insertFiles(candidate, application);

      Logger.info(
          'Application received for job ' +
            job.Id +
            ' (candidate ' +
            candidate.Id +
            ')'
        )
        .addTag(LOG_TAG);
      Logger.saveLog();
      result.success = true;
      result.message =
        'Thank you, your application for ' +
        job.Name +
        ' has been received.';
      return result;
    } catch (ValidationException ex) {
      Database.rollback(savepoint);
      result.message = ex.getMessage();
      return result;
    } catch (Exception ex) {
      Database.rollback(savepoint);
      Logger.error('Application failed for job ' + application?.jobId)
        .setExceptionDetails(ex)
        .addTag(LOG_TAG);
      Logger.saveLog();
      result.message = 'Your application could not be sent. Please try again later.';
      return result;
    }
  }

  private void validate(Application application) {
    if (application == null || application.jobId == null) {
      throw new ValidationException('Please choose a job to apply to.');
    }
    require(application.fullName, 'Full name', 80);
    require(application.email, 'Email', 80);
    if (!EMAIL_PATTERN.matcher(application.email.trim()).matches()) {
      throw new ValidationException('Please enter a valid email address.');
    }
    limitLength(application.phone, 'Phone', 40);
    limitLength(application.country, 'Country', 80);
    if (application.consent != true) {
      throw new ValidationException(
        'Please accept that we store your data to process your application.'
      );
    }

    if (application.cv == null || String.isBlank(application.cv.base64)) {
      throw new ValidationException('Please upload your CV.');
    }
    Integer total = checkFile(
      application.cv,
      CV_EXTENSIONS,
      'Your CV must be a PDF or Word document.'
    );
    if (total > MAX_CV_BYTES) {
      throw new ValidationException('Your CV must be smaller than 2 MB.');
    }

    List<UploadedFile> otherFiles = application.otherFiles == null
      ? new List<UploadedFile>()
      : application.otherFiles;
    if (otherFiles.size() > MAX_OTHER_FILES) {
      throw new ValidationException(
        'You can add up to ' + MAX_OTHER_FILES + ' other documents.'
      );
    }
    for (UploadedFile file : otherFiles) {
      total += checkFile(
        file,
        OTHER_EXTENSIONS,
        'Other documents must be PDF, Word, PNG or JPG files.'
      );
    }
    if (total > MAX_TOTAL_BYTES) {
      throw new ValidationException(
        'All files together must be smaller than 3 MB.'
      );
    }
  }

  /** Returns the decoded size. The extension is checked, not trusted: the file is never executed or shown inline. */
  private Integer checkFile(
    UploadedFile file,
    Set<String> extensions,
    String typeMessage
  ) {
    if (
      file == null ||
      String.isBlank(file.fileName) ||
      String.isBlank(file.base64)
    ) {
      throw new ValidationException('One of the files is empty.');
    }
    if (file.fileName.length() > 255) {
      throw new ValidationException('A file name is too long.');
    }
    if (
      !extensions.contains(file.fileName.substringAfterLast('.').toLowerCase())
    ) {
      throw new ValidationException(typeMessage);
    }
    // Base64 is 4 characters per 3 bytes: estimate before decoding to fail fast on huge files.
    return (file.base64.length() / 4) * 3;
  }

  private Job__c getOpenJob(Id jobId) {
    Date today = Date.today();
    List<Job__c> jobs = [
      SELECT Id, Name
      FROM Job__c
      WHERE Id = :jobId AND (Due_Date__c = NULL OR Due_Date__c >= :today)
    ];
    if (jobs.isEmpty()) {
      throw new ValidationException('This job is no longer open.');
    }
    return jobs[0];
  }

  private Candidate__c findCandidate(String email) {
    List<Candidate__c> candidates = [
      SELECT Id, Name
      FROM Candidate__c
      WHERE Email__c = :email
      ORDER BY CreatedDate
      LIMIT 1
    ];
    return candidates.isEmpty() ? null : candidates[0];
  }

  private Boolean hasApplied(Id candidateId, Id jobId) {
    return [
        SELECT COUNT()
        FROM Job_Applicant__c
        WHERE Candidate__c = :candidateId AND Job__c = :jobId
      ] > 0;
  }

  private void insertFiles(Candidate__c candidate, Application application) {
    List<ContentVersion> versions = new List<ContentVersion>{
      toVersion(candidate, application.cv, 'CV')
    };
    if (application.otherFiles != null) {
      for (UploadedFile file : application.otherFiles) {
        versions.add(toVersion(candidate, file, 'Document'));
      }
    }
    insert versions;
  }

  private ContentVersion toVersion(
    Candidate__c candidate,
    UploadedFile file,
    String kind
  ) {
    String fileName = file.fileName.trim();
    return new ContentVersion(
      Title = (kind +
        ' - ' +
        candidate.Name +
        ' - ' +
        fileName.substringBeforeLast('.'))
        .left(255),
      PathOnClient = fileName,
      VersionData = EncodingUtil.base64Decode(file.base64),
      FirstPublishLocationId = candidate.Id
    );
  }

  private void require(String value, String label, Integer maxLength) {
    if (String.isBlank(value)) {
      throw new ValidationException(label + ' is required.');
    }
    limitLength(value, label, maxLength);
  }

  private void limitLength(String value, String label, Integer maxLength) {
    if (value != null && value.trim().length() > maxLength) {
      throw new ValidationException(
        label + ' must be at most ' + maxLength + ' characters.'
      );
    }
  }

  private String trimToNull(String value) {
    return String.isBlank(value) ? null : value.trim();
  }
}
