@IsTest
private class AiPromptTest {
  @IsTest
  static void parsesJsonInsideFencesAndText() {
    Map<String, Object> data = AiPrompt.parseJsonObject(
      'Here is the card:\n```json\n{"name": "Sara", "years": 8, "skills": [{"name": "Apex"}]}\n```'
    );
    Assert.areEqual('Sara', AiPrompt.text(data, 'name'));
    Assert.areEqual(8, AiPrompt.num(data, 'years'));
    Assert.areEqual(1, AiPrompt.objects(data, 'skills').size());
  }

  @IsTest
  static void rejectsAnswersThatAreNotJson() {
    for (
      String text : new List<String>{ null, 'no json here', '{"broken": }' }
    ) {
      try {
        AiPrompt.parseJsonObject(text);
        Assert.fail('Expected an AiException for ' + text);
      } catch (AiPrompt.AiException ex) {
        Assert.isTrue(ex.getMessage().contains('JSON'));
      }
    }
  }

  @IsTest
  static void readersAreSafeWithAnyType() {
    Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(
      '{"a": "N/A", "b": " 7.5 ", "c": "abc", "d": true, "e": "true", "f": 3, "g": "x", "h": null}'
    );
    Assert.isNull(
      AiPrompt.text(data, 'a'),
      'placeholder values mean "no value"'
    );
    Assert.isNull(AiPrompt.text(data, 'h'));
    Assert.areEqual(7.5, AiPrompt.num(data, 'b'));
    Assert.isNull(AiPrompt.num(data, 'c'));
    Assert.areEqual(3, AiPrompt.num(data, 'f'));
    Assert.isTrue(AiPrompt.bool(data, 'd'));
    Assert.isTrue(AiPrompt.bool(data, 'e'));
    Assert.isFalse(AiPrompt.bool(data, 'g'));
    Assert.isTrue(AiPrompt.objects(data, 'g').isEmpty());
    Assert.isNull(AiPrompt.text(null, 'a'));
  }

  @IsTest
  static void emptyAnswerIsAnError() {
    AiPromptFake.install().answer('Any', '  ');
    try {
      AiPrompt.run('Any', new Map<String, Object>());
      Assert.fail('Expected an AiException');
    } catch (AiPrompt.AiException ex) {
      Assert.isTrue(ex.getMessage().contains('empty'));
    }
  }

  @IsTest
  static void removesCourtesyLines() {
    AiPromptFake.install()
      .answer(
        'Any',
        'Thank you for your question.\n\nSara knows Apex.\nThanks for asking!'
      );
    Assert.areEqual(
      'Sara knows Apex.',
      AiPrompt.run('Any', new Map<String, Object>())
    );
    Assert.areEqual(
      'Hire Sara.',
      AiPrompt.withoutCourtesy(
        'Hire Sara. Thank you for your time in reviewing this summary.'
      )
    );
  }

  @IsTest
  static void fileInputHasTheDocumentId() {
    Id documentId = '069000000000001AAA';
    Assert.areEqual(
      new Map<String, Object>{ 'id' => documentId },
      AiPrompt.fileInput(documentId)
    );
  }

  @IsTest
  static void readsEveryNumberType() {
    Map<String, Object> data = new Map<String, Object>{
      'decimal' => 1.5,
      'integer' => 2,
      'long' => 3L,
      'double' => Double.valueOf(4.5),
      'missing' => null
    };
    Assert.areEqual(1.5, AiPrompt.num(data, 'decimal'));
    Assert.areEqual(2, AiPrompt.num(data, 'integer'));
    Assert.areEqual(3, AiPrompt.num(data, 'long'));
    Assert.areEqual(4.5, AiPrompt.num(data, 'double'));
    Assert.isNull(AiPrompt.num(data, 'missing'));
    Assert.isNull(AiPrompt.num(null, 'decimal'));
  }
}
