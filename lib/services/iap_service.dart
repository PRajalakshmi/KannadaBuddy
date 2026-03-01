import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// Product ID for the monthly subscription. Must match the id configured in
/// Google Play Console (Android) and App Store Connect (iOS).
const String kSubscriptionProductId = 'kannadabuddy_pro_monthly';

/// Handles in-app purchase for the Pro subscription: load product, buy, restore,
/// and notifies [onPurchaseSuccess] when the user has an active subscription.
/// [onPurchaseSuccess] receives the purchase token (for linking to user on backend).
class IAPService {
  IAPService({
    required this.onPurchaseSuccess,
    this.onPurchaseCancelOrError,
  });

  /// Called with purchase token (serverVerificationData) when purchase/restore succeeds.
  final Future<void> Function(String? purchaseToken) onPurchaseSuccess;
  final void Function()? onPurchaseCancelOrError;

  static final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _subscription;
  ProductDetails? _productDetails;
  bool _isAvailable = false;

  bool get isAvailable => _isAvailable;
  ProductDetails? get productDetails => _productDetails;

  /// Call once at app start (e.g. before showing paywall). Returns true if store is available.
  Future<bool> initialize() async {
    _isAvailable = await _iap.isAvailable();
    if (!_isAvailable) return false;
    _subscription = _iap.purchaseStream.listen(
      _onPurchaseUpdate,
      onDone: () => _subscription?.cancel(),
      onError: (Object e) => debugPrint('IAP purchaseStream error: $e'),
    );
    await loadProducts();
    return true;
  }

  void dispose() {
    _subscription?.cancel();
  }

  Future<void> loadProducts() async {
    if (!_isAvailable) return;
    final response = await _iap.queryProductDetails({kSubscriptionProductId});
    if (response.notFoundIDs.isNotEmpty) {
      debugPrint('IAP product not found: ${response.notFoundIDs}');
      return;
    }
    final product = response.productDetails.isEmpty ? null : response.productDetails.first;
    if (product != null) _productDetails = product;
  }

  /// Start purchase flow. Result comes via [purchaseStream] and [onPurchaseSuccess].
  Future<bool> buy() async {
    if (!_isAvailable || _productDetails == null) return false;
    final param = PurchaseParam(productDetails: _productDetails!);
    return _iap.buyNonConsumable(purchaseParam: param);
  }

  /// Restore previous purchases. Result comes via [purchaseStream].
  Future<void> restore() async {
    if (!_isAvailable) return;
    await _iap.restorePurchases();
  }

  void _onPurchaseUpdate(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.productID != kSubscriptionProductId) continue;
      switch (purchase.status) {
        case PurchaseStatus.pending:
          break;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          if (purchase.pendingCompletePurchase) {
            await _iap.completePurchase(purchase);
            final token = purchase.verificationData.serverVerificationData;
            await onPurchaseSuccess(token.isEmpty ? null : token);
          }
          break;
        case PurchaseStatus.error:
          debugPrint('IAP error: ${purchase.error}');
          onPurchaseCancelOrError?.call();
          break;
        case PurchaseStatus.canceled:
          onPurchaseCancelOrError?.call();
          break;
      }
    }
  }
}
