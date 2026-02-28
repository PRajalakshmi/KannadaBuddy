import 'package:flutter_test/flutter_test.dart';
import 'package:kanndabuddy/services/iap_service.dart';

void main() {
  group('IAPService / subscription config', () {
    test('subscription product ID is non-empty and stable', () {
      expect(kSubscriptionProductId, isNotEmpty);
      expect(kSubscriptionProductId, 'kannadabuddy_pro_monthly');
    });
  });
}
