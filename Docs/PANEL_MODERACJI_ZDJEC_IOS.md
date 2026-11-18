# CK-04e.3j.3c.3 — ekran moderatora i lokalna blokada zdjęcia

Ekran w kontrolowanym Debug Runtime korzysta z rzeczywistego [hosta i magazynu decyzji](MAGAZYN_I_HOST_MODERACJI_IOS.md). Pokazuje kolejkę, aktualny obraz, osobne zatwierdzenie lub odrzucenie, jawne potwierdzenie oraz wynik. Nie publikuje zdjęcia za autora. Sam widok nie przyznaje roli: uprawnienia nadal sprawdza [gateway](HTTP_MODERACJI_ZDJEC.md). Zwykłe wejście aplikacji pozostaje Firebase, flagi usług pozostają wyłączone.

## Obraz i świadoma decyzja

AvatarReviewView działa w istniejącym NavigationStack i otrzymuje konkretny host. Lokalny stan zawiera wyłącznie wybór metadanych, opaque presentation i potwierdzenie. Piksele są pobierane przez image(for:) przy renderowaniu; nie trafiają do State, journala lub cache moderatora. Zadanie widocznego obrazu potwierdza dokładną prezentację po oddaniu sterowania SwiftUI. Bez tego host nie pozwala na decyzję. To warunek renderowania, nie dowód przeczytania obrazu przez człowieka.

Przyciski wymagają bieżącej prezentacji i wolnego hosta. Osobny alert zawiera decyzję, jej skutek, potwierdzenie oraz anulowanie. Wygaśnięcie prezentacji zamyka oczekujące potwierdzenie. Background, wyjście lub zmiana konta odcinają obraz i widok decyzji. Powrót z tła wymaga jawnego ponownego otwarcia panelu. Stara odpowiedź nie może odtworzyć podglądu innego konta. Obraz ma privacySensitive; nie jest to fizyczne wymazanie RAM lub zabezpieczenie przed zrzutem ekranu.

Form obsługuje przewijanie i systemowy rozmiar tekstu. Widok rozróżnia brak roli, pustą kolejkę, zajętość, wygasły podgląd oraz zamknięty panel. Odmowa roli nie wylogowuje użytkownika.

## Wynik po utracie odpowiedzi

Niepewna decyzja zachowuje identyfikatory i blokuje kolejny wybór. „Sprawdź wynik” wykonuje wyłącznie exact recovery zapisanej intencji. Potwierdzony wynik, brak zastosowania i zastąpiony stan mają różne komunikaty. Zastąpiony stan nie oznacza historycznej porażki lub sukcesu. Dopiero „Rozumiem” na bieżącym wyniku usuwa rozliczony wpis. Nie ma automatycznego ponawiania decide, nowego ID ani odświeżania receipt.

## Pozostałe lokalne powierzchnie

Host emituje typowane pending przed wywołaniem API decyzji oraz resolved dopiero po trwałym zapisie wyniku. GatewayCommunityAvatarHost na pending odcina wszystkie lokalne zdjęcia danego właściciela: mapę, profil, wiadomości i własny edytor. Unieważnia cache i trwające odczyty. Spóźniona odpowiedź nie przywraca starych pikseli; inne osoby zachowują własne podglądy.

Blokady są związane z ID decyzji. Starszy wynik nie usuwa nowszej blokady. Zdjęcie może wrócić dopiero po nowym chronionym odczycie. Własny edytor wymaga także świeżego snapshotu właściciela. Limit 32 nierozliczonych blokad zamyka dostęp zamiast odrzucenia ochrony; reset następuje z nowym wiązaniem.

Przed otwarciem społeczności Runtime odczytuje pending metadane przez readonly peek journala. Dopiero po ponownej kontroli konta wiąże host zdjęć z odzyskaną blokadą. Peek nie tworzy wpisu, nie obraca lease, nie potwierdza wyniku i nie naprawia uszkodzonych danych. Odczyt magazynu nadal wykonuje szeregowy backend poza MainActor. W ten sposób restart aplikacji nie omija blokady przez samo otwarcie mapy bez panelu moderatora.

Jest to lokalne zachowanie aktualnego klienta. Odcięcie zdalnego klienta, rola, generacja i uprawnienia pozostają obowiązkiem serwera. Sama decyzja nie cofa pliku już odczytanego przez inną osobę.

## Weryfikacja i granice

[Raport etapu](evidence/avatar-review-ui-local-tests.json) zawiera końcowe liczby, SHA źródeł/logów, wyniki kompilacji, testów i kontroli negatywnej. Dziewięć nowych testów pakietu obejmuje wszystkie powierzchnie, dokładną blokadę i świeży odczyt, spóźniony wynik, bootstrap, własny snapshot, readonly peek oraz kolejność zdarzeń przed dispatch i po recovery.

Dziesięć testów UI używa rzeczywistego widoku, hosta, dekodera ImageIO, klienta HTTP i kodeka journala. Tożsamości, tokeny i transport są syntetyczne. Wariant DEBUG korzysta z osobnego plikowego storage i modelu serwera pod losowym UUID. Test restartu faktycznie kończy proces aplikacji i uruchamia go ponownie, zachowując ten sam testowy katalog; licznik dowodzi pojedynczego decide. Nie jest to odbiór Keychain OS, CloudKit, SIWA lub dwóch prawdziwych kont. Narzędzia i dane testowe są wykluczone z Release.

Poprawiono także ostrzeżenia izolacji istniejących preview/edytora: stałe syntetyczne są nonisolated, a przekazywane asynchroniczne funkcje mają jawny Sendable kontrakt i opakowania w miejscach wywołania. Nie wyłączono diagnostyki współbieżności ani nie dodano unsafe rzutowań.

Nadal wymagane są: świadome ponowne opublikowanie zatwierdzonego zdjęcia autora bez dawnego upload journala; odbiór PhotosPicker/iCloud Photos i Keychain na urządzeniu; diagnoza wcześniejszych ostrzeżeń ramek SwiftUI przy otwieraniu czatu i ustawień; zgłoszenia, kontakt, retencja i osierocone pliki; rzeczywiste role/schemat/hosty/SIWA/osobna tożsamość serwisowa/limity Free i dwa zwykłe konta. Ten etap nie uruchamia usług, nie rozszerza wygasłych zgód SDK, nie zmienia Production lub Firebase i nie oznacza gotowości do TestFlight.

Dodatkowo obie konfiguracje skompilowano z głównego checkoutu z zachowanym, niezacommitowanym projektem użytkownika. Różnice projektu obejmują pustą listę buildRules i membershipExceptions pliku Debug entitlements; jego źródło nie trafiło do żadnego pakietu. Ponownie sprawdzono brak aktywacji/probe, zgodność manifestu prywatności i wykluczenie testowego moderatora z Release. SHA projektu pozostało bez zmian.
