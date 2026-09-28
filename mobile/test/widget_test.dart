import 'package:flutter_test/flutter_test.dart';
import 'package:mesenger/core/constants/app_strings.dart';

void main() {
  test('приложение содержит русские строки интерфейса', () {
    expect(S.welcomeTitle, 'Добро пожаловать');
    expect(S.datingTitle, 'Знакомства');
  });
}
