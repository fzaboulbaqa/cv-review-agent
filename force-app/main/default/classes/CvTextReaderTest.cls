@IsTest
private class CvTextReaderTest {
  @IsTest
  static void pdfIsReadByTheAi() {
    AiPromptFake fake = AiPromptFake.install()
      .answer(Constants.TEMPLATE_READ_CV, 'Sara Haddad\nApex developer');
    ContentVersion version = upload('cv.pdf', Blob.valueOf('%PDF-fake'));

    CvTextReader.CvText result = CvTextReader.read(version);

    Assert.areEqual('Sara Haddad\nApex developer', result.text);
    Assert.isNull(result.problem);
    Assert.areEqual(1, fake.count(Constants.TEMPLATE_READ_CV));
    Assert.areEqual(
      AiPrompt.fileInput(version.ContentDocumentId),
      fake.inputs[0].get('CvFile')
    );
  }

  @IsTest
  static void pdfWithoutTextIsReported() {
    AiPromptFake.install()
      .answer(Constants.TEMPLATE_READ_CV, CvTextReader.NO_TEXT);
    CvTextReader.CvText result = CvTextReader.read(
      upload('scan.pdf', Blob.valueOf('%PDF-fake'))
    );
    Assert.isNull(result.text);
    Assert.isTrue(result.problem.contains('No text was found'));
  }

  @IsTest
  static void docxIsReadInApex() {
    AiPromptFake fake = AiPromptFake.install();
    Compression.ZipWriter writer = new Compression.ZipWriter();
    writer.addEntry(
      'word/document.xml',
      Blob.valueOf(
        '<w:document><w:body><w:p><w:r><w:t>Julia Novak</w:t></w:r></w:p>' +
        '<w:p><w:r><w:t>Apex &amp; LWC</w:t><w:tab/><w:t>2020</w:t></w:r></w:p></w:body></w:document>'
      )
    );

    CvTextReader.CvText result = CvTextReader.read(
      upload('cv.docx', writer.getArchive())
    );

    Assert.areEqual('Julia Novak\nApex & LWC\t2020', result.text);
    Assert.areEqual(0, fake.calls.size(), 'no AI call for a Word file');
  }

  @IsTest
  static void damagedDocxIsReportedNotThrown() {
    AiPromptFake.install();
    Compression.ZipWriter writer = new Compression.ZipWriter();
    writer.addEntry('other.xml', Blob.valueOf('<x/>'));
    CvTextReader.CvText result = CvTextReader.read(
      upload('cv.docx', writer.getArchive())
    );
    Assert.isNull(result.text);
    Assert.isTrue(result.problem.contains('may be damaged'), result.problem);
  }

  @IsTest
  static void textFileIsReadAndLongTextIsCut() {
    AiPromptFake.install();
    String longText = 'a'.repeat(CvTextReader.MAX_TEXT_LENGTH + 10);
    CvTextReader.CvText result = CvTextReader.read(
      upload('cv.txt', Blob.valueOf(longText))
    );
    Assert.areEqual(CvTextReader.MAX_TEXT_LENGTH, result.text.length());
    Assert.isTrue(result.truncated);
  }

  @IsTest
  static void oldWordFileIsNotReadable() {
    AiPromptFake fake = AiPromptFake.install();
    CvTextReader.CvText result = CvTextReader.read(
      upload('cv.doc', Blob.valueOf('binary'))
    );
    Assert.isNull(result.text);
    Assert.isTrue(result.problem.contains('.doc file'), result.problem);
    Assert.areEqual(0, fake.calls.size());
  }

  @IsTest
  static void aiErrorsAreRaised() {
    AiPromptFake fake = AiPromptFake.install();
    fake.failing.add(Constants.TEMPLATE_READ_CV);
    try {
      CvTextReader.read(upload('cv.pdf', Blob.valueOf('%PDF-fake')));
      Assert.fail('Expected an AiException');
    } catch (AiPrompt.AiException ex) {
      Assert.isTrue(ex.getMessage().contains('not available'));
    }
  }

  private static ContentVersion upload(String fileName, Blob data) {
    return TestDataFactory.createFile(null, fileName, data);
  }
}
