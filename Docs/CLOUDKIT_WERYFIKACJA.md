# Weryfikacja migracji CloudKit

Stan: 12 listopada 2026. **Migracja nie jest odebrana i aplikacja nie została przełączona na CloudKit.**

## CK-01 — rozpoznanie i kontrola konfiguracji

- Potwierdzono zespół Apple i Bundle ID źródeł. Lokalny profil nie zawiera CloudKit.
- Konsola wyświetliła brak widocznych kontenerów. Dostęp do identyfikatorów początkowo blokowała umowa; po samodzielnej akceptacji przez właściciela lista została odblokowana.
- Przygotowano rejestrację App ID; zatwierdzenie nie zostało wykonane.
- `cktool get-teams`: brak zapisanego tokenu zarządzania. Nie tworzono ani nie eksportowano tokenu.
- `python3 scripts/test_cloudkit_preflight.py`: 5 testów przeszło — brak konfiguracji, wildcard, inny kontener, środowisko i zgodna konfiguracja syntetyczna.
- Preflight dla obecnych entitlements zwraca poprawnie `needs-configuration`; nie ma niejawnego fallbacku do zgadywanego kontenera.

## CK-02 — niezależna podstawa konta iCloud

- `swift test --package-path EchoesCloudKit`: 8 testów przeszło na macOS. Testowano brak/ograniczenie konta, zmianę konta, unieważnianie spóźnionych odpowiedzi, anulowanie, zakończenie monitorowania, redakcję błędów, konfigurację i retryAfter.
- Pakiet skompilowany dla iOS Simulator (arm64 i x86_64), bez podpisywania. Nie uruchamiał natywnych operacji CloudKit.
- Źródło natywne jest przygotowane, lecz nie jest wywoływane przez testy stubów ani włączone do głównego klienta.

## Obowiązkowe dowody przed odbiorem CK-01/CK-02

| Próba | Stan | Warunek odbioru |
| --- | --- | --- |
| Jawny App ID, kontener i profil | Oczekuje | Spójne uprawnienia portalu, podpisanej aplikacji i rzeczywistego kontenera. |
| Dwa konta A/B w Development | Niewykonana | B nie odczyta prywatnych danych A ani nie zmieni cudzych rekordów; opisać faktyczny zakres publicznego odczytu. |
| Brak iCloud i zmiana konta na urządzeniu | Testy stubów przeszły; live niewykonany | Brak przecieku cache i poprawny komunikat w prawdziwym hoście. |
| Offline, ponowienie i konflikt | Klasyfikacja błędów przetestowana; live niewykonany | Brak duplikatów i nadpisania zmian. |
| Spójność roli i dostępu z pominięciem UI | Niewykonana | Sprawdzić bezpośrednie operacje w Development; nie utożsamiać filtrów klienta z ACL. |
| Fizyczne kasowanie i moderacja | Niezaimplementowane w CloudKit | Konkretny wykonawca i proces także bez aktywnego klienta. |

Nie wykonano promocji schematu, transferu starych danych, testów penetracyjnych, pomiaru baterii ani pełnego testu obciążeniowego. Wyniki poprzedniej implementacji Firebase są historyczne i nie stanowią odbioru CloudKit.
