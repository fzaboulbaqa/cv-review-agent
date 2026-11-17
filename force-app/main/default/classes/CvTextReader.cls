/**
 * Gets the plain text of a CV file. The text is saved once in Candidate__c.CV_Text__c and is the
 * source of truth for the card, the questions and the comparison.
 *
 *  - PDF:  read by the AI (prompt template CV_Read_Text with the file as input). The model sees
 *          the PDF itself, scanned CVs included.
 *  - DOCX: read in Apex. A .docx is a zip: the text is in word/document.xml. (Tested: the
 *          template's file input doesn't accept Word files, the model gets nothing.)
 *  - TXT:  read as is.
 *  - Anything else (old binary .doc, images, ...): not readable. The reason is returned and
 *    becomes a "Missing" flag on the card, so the recruiter knows to ask for a PDF.
 */
public with sharing class CvTextReader {
  /** Answer of the read template when the file has no CV text (empty, not a CV, unreadable). */
  public static final String NO_TEXT = 'NO_CV_TEXT';
  public static final Set<String> READABLE_EXTENSIONS = new Set<String>{
    'pdf',
    'docx',
    'txt'
  };
  @TestVisible
  private static final Integer MAX_TEXT_LENGTH = 131072; // CV_Text__c length

  private class CvReadException extends Exception {
  }

  public class CvText {
    public String text;
    /** Why there is no text, written for the recruiter. Null when the text was read. */
    public String problem;
    public Boolean truncated = false;
  }

  /** version: needs Id, ContentDocumentId, FileExtension and Title. */
  public static CvText read(ContentVersion version) {
    CvText result = new CvText();
    String extension = version.FileExtension == null
      ? ''
      : version.FileExtension.toLowerCase();
    try {
      if (extension == 'pdf') {
        String answer = AiPrompt.run(
          Constants.TEMPLATE_READ_CV,
          new Map<String, Object>{
            'CvFile' => AiPrompt.fileInput(version.ContentDocumentId)
          }
        );
        result.text = answer.contains(NO_TEXT) ? null : answer;
      } else if (extension == 'docx') {
        result.text = docxText(versionData(version.Id));
      } else if (extension == 'txt') {
        result.text = versionData(version.Id).toString();
      } else {
        result.problem =
          'The CV "' +
          version.Title +
          '" is a .' +
          (String.isBlank(extension) ? '(unknown)' : extension) +
          ' file, which can\'t be read. Ask the candidate for a PDF or DOCX version.';
        return result;
      }
    } catch (AiPrompt.AiException ex) {
      throw ex;
    } catch (Exception ex) {
      // A damaged file is a data problem, not a system error: report it on the card, log the details.
      Logger.warn('CV file ' + version.Id + ' could not be read')
        .setExceptionDetails(ex)
        .addTag(Constants.LOG_TAG_CV_EXTRACTION);
      result.problem =
        'The CV "' +
        version.Title +
        '" could not be read: the file may be damaged or not a real PDF / Word document. ' +
        'Ask the candidate for a new copy.';
      return result;
    }

    if (String.isBlank(result.text)) {
      result.text = null;
      result.problem =
        'No text was found in the CV "' +
        version.Title +
        '" (empty, or not a CV).';
    } else if (result.text.length() > MAX_TEXT_LENGTH) {
      result.text = result.text.left(MAX_TEXT_LENGTH);
      result.truncated = true;
    }
    return result;
  }

  /** Text of a .docx: paragraphs become lines, tags are removed, XML entities decoded. */
  @TestVisible
  private static String docxText(Blob docx) {
    Compression.ZipReader reader = new Compression.ZipReader(docx);
    Compression.ZipEntry entry = reader.getEntry('word/document.xml');
    if (entry == null) {
      throw new CvReadException('not a Word document');
    }
    String xml = reader.extract(entry).toString();
    String text = xml.replace('</w:p>', '\n')
      .replace('<w:tab/>', '\t')
      .replace('<w:br/>', '\n')
      .replaceAll('<[^>]+>', '');
    text = text.replace('&lt;', '<')
      .replace('&gt;', '>')
      .replace('&quot;', '"')
      .replace('&apos;', '\'')
      .replace('&amp;', '&');
    return text.replaceAll('\n{3,}', '\n\n').trim();
  }

  private static Blob versionData(Id versionId) {
    return [
      SELECT VersionData
      FROM ContentVersion
      WHERE Id = :versionId
      WITH USER_MODE
    ]
    .VersionData;
  }
}
