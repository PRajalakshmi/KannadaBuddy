class TransliterationService {
  // Independent vowels
  static const Map<String, String> vowels = {
    'ಅ': 'a',
    'ಆ': 'aa',
    'ಇ': 'i',
    'ಈ': 'ee',
    'ಉ': 'u',
    'ಊ': 'oo',
    'ಋ': 'ru',
    'ಎ': 'e',
    'ಏ': 'ae',
    'ಐ': 'ai',
    'ಒ': 'o',
    'ಓ': 'oa',
    'ಔ': 'au',
    'ಂ': 'm',
    'ಃ': 'h',
  };

  // Base consonants (with inherent 'a')
  static const Map<String, String> consonants = {
    'ಕ': 'k',
    'ಖ': 'kh',
    'ಗ': 'g',
    'ಘ': 'gh',
    'ಙ': 'ng',
    'ಚ': 'ch',
    'ಛ': 'chh',
    'ಜ': 'j',
    'ಝ': 'jh',
    'ಞ': 'ny',
    'ಟ': 't',
    'ಠ': 'th',
    'ಡ': 'd',
    'ಢ': 'dh',
    'ಣ': 'n',
    'ತ': 'th',
    'ಥ': 'thh',
    'ದ': 'd',
    'ಧ': 'dh',
    'ನ': 'n',
    'ಪ': 'p',
    'ಫ': 'ph',
    'ಬ': 'b',
    'ಭ': 'bh',
    'ಮ': 'm',
    'ಯ': 'y',
    'ರ': 'r',
    'ಲ': 'l',
    'ವ': 'v',
    'ಶ': 'sh',
    'ಷ': 'sh',
    'ಸ': 's',
    'ಹ': 'h',
    'ಳ': 'l',
  };

  // Vowel signs (matras)
  static const Map<String, String> matras = {
    'ಾ': 'aa',
    'ಿ': 'i',
    'ೀ': 'ee',
    'ು': 'u',
    'ೂ': 'oo',
    'ೆ': 'e',
    'ೇ': 'ae',
    'ೈ': 'ai',
    'ೊ': 'o',
    'ೋ': 'oa',
    'ೌ': 'au',
  };

  static const String halant = '್';

  // Special conjuncts
  static const Map<String, String> conjuncts = {
    'ಕ್ಷ': 'ksha',
    'ಜ್ಞ': 'gnya',
  };

  String transliterate(String input) {
    String output = '';
    int i = 0;

    while (i < input.length) {
      String current = input[i];

      // Handle conjuncts first (2-char lookahead)
      if (i + 1 < input.length) {
        String twoChar = input.substring(i, i + 2);
        if (conjuncts.containsKey(twoChar)) {
          output += conjuncts[twoChar]!;
          i += 2;
          continue;
        }
      }

      // Independent vowels
      if (vowels.containsKey(current)) {
        output += vowels[current]!;
        i++;
        continue;
      }

      // Consonants
      if (consonants.containsKey(current)) {
        String base = consonants[current]!;

        // Look ahead for matra or halant
        if (i + 1 < input.length) {
          String next = input[i + 1];

          // Halant (remove inherent 'a')
          if (next == halant) {
            output += base;
            i += 2;
            continue;
          }

          // Matra modifies vowel
          if (matras.containsKey(next)) {
            output += base + matras[next]!;
            i += 2;
            continue;
          }
        }

        // Default inherent 'a'
        output += base + 'a';
        i++;
        continue;
      }

      // Space or punctuation
      output += current;
      i++;
    }

    return output;
  }
}