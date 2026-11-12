# CloudKit: rejestracja aplikacji i decyzje o dostępie

Stan: 12 listopada 2026. Właściciel zatwierdził rejestrację App ID/kontenera i prywatną próbę urządzeniową. Następnie wybrał ograniczanie odczytu mapy/czatu przez dodatkową usługę, z uprzednim sprawdzeniem darmowego limitu. Nie zatwierdził płatności ani bezpośredniego publicznego odczytu tych danych.

## Dlaczego App ID trzeba zarejestrować

Bundle ID `mpvEcho.Echo` jest wpisany w projekcie Xcode. To nie jest to samo co jawny App ID w portalu Apple ani rejestracja aplikacji w Firebase. Na sprawdzonej liście zespołu `22YC9RAP4P` nie było jawnego App ID dla tego Bundle ID; był ogólny wildcard. CloudKit wymaga jawnego App ID z usługą iCloud oraz przypisanym kontenerem. Dlatego po odrębnej zgodzie właściciela zarejestrowano App ID i przypisano zatwierdzony kontener `iCloud.mpvEcho.Echo`, zachowując istniejący Bundle ID, bez tworzenia nowej aplikacji w App Store. Zgodny podpisany Debug przeszedł syntetyczną próbę prywatną; nie oznacza to zatwierdzenia wariantu A/B.

Początkowe kliknięcie Register zablokowała automatyczna kontrola. Później właściciel jednoznacznie zatwierdził tę operację, osobno utworzenie/przypisanie kontenera oraz podpisywanie, instalację i próbę. Operacje wykonano po tych zgodach; akceptacja umowy sama nie była traktowana jako rejestracja.

## Co oznacza zakres 3 km

Przykład: użytkownicy Anna i Bartek są od siebie 100 km.

- Filtrowanie widoku: zwykła aplikacja pokazuje Bartkowi osoby w jego okolicy. Jeśli rekord Anny ma publiczny odczyt w CloudKit, inny klient może zapytać także o rekord Anny. Samo przesunięcie/zmiana zapytania nie wymaga złamania uprawnień Apple, jeśli rekord jest publiczny.
- Ograniczanie odpowiedzi: zaufana usługa sprawdza uprawnienia i zakres oraz zwraca wybrany zbiór; klient nie może czytać tych samych chronionych rekordów bezpośrednio. To wymaga odpowiedniego projektu ról i bramki, nie samego filtra Swift.
- Nawet usługa sprawdzająca podane współrzędne nie dowodzi fizycznego pobytu telefonu. Nie obiecujemy całkowitej odporności na fałszowanie GPS ani cofnięcia danych już zapisanych przez odbiorcę.

## Dwie niezależne decyzje

Poprzednie skróty A/B łączyły dwa różne zagadnienia. Należy ustalić osobno:

1. **Publiczność danych:** co jest celowo publiczne, co widoczne tylko właścicielowi/uczestnikom, a co zależy od ograniczeń okolicy.
2. **Egzekwowanie zasad:** kto sprawdza spam, dopuszczalną treść, zgłoszenia, decyzje moderatora i fizyczne kasowanie. Można mieć publiczne profile i jednocześnie zaufaną usługę kontrolującą zapisy.

CloudKit jest backendem: przechowuje dane i sprawdza uprawnienia Apple. Nie jest automatyczną implementacją własnych reguł społecznościowych. Rola Creator pomaga chronić cudze rekordy; blokada w UI nie jest tym samym co odmowa odczytu przez usługę. Throttling Apple chroni infrastrukturę i nie zastępuje własnych limitów produktu.

## Skutki wariantów

| Przypadek | Bezpośrednia publiczna baza CloudKit | CloudKit z odpowiednio zaprojektowaną zaufaną usługą |
| --- | --- | --- |
| Publiczny pseudonim, opis, avatar | Odpowiedni model, jeśli właściciel chce ich publiczności. | Mogą nadal pozostać publiczne. |
| Osoba daleko od właściciela rekordu | Może odczytać publiczne rekordy innym zapytaniem. | Zakres chronionych odpowiedzi może być ograniczany, jeśli nie ma bocznej ścieżki bezpośredniego odczytu. |
| Blokada użytkownika | Oficjalny klient ukrywa autora; nie odbiera mu sama prawa odczytu publicznych danych. | Usługa może odmówić nowych odpowiedzi dla danego konta; nie cofnie kopii ani nie zagwarantuje, że osoba nie utworzy innego konta. |
| Zmodyfikowany klient wysyła spam | Lokalny filtr i licznik da się ominąć; pozostają role i limity Apple. | Usługa może egzekwować własne limity i walidację przed zapisem. |
| Zgłoszenie do moderatora | Potrzebny poufny kanał; prywatna baza zgłaszającego nie daje automatycznie dostępu obsłudze. | Poufna obsługa zgłoszeń może być częścią usługi. |
| Wygasła wiadomość | Klient może ją ukryć; trzeba osobno rozwiązać kasowanie bez aktywnego autora. | Operator/zadanie usługi może wykonywać fizyczne kasowanie. |
| Utrzymanie | Mniej własnej infrastruktury, lecz więcej ograniczeń zachowania produktu. | Więcej implementacji i utrzymania; koszt hostingu wymaga wyceny. |

## Propozycja dla Echoes do doprecyzowania

- Profil: tylko świadomie publiczne pola i avatar; nigdy prywatne ustawienia ani dokładny GPS.
- Prywatne dane: baza prywatna, a w przyszłych rozmowach dostęp ograniczony do uczestników zgodnie z osobnym projektem.
- Obecność i lokalny czat: najpierw ustalić, czy okolica jest wyłącznie sposobem odkrywania treści, czy warunkiem dostępu do nich. To decyzja produktowa i prywatności, nie detal biblioteki.
- Moderacja i retencja: zaprojektować działający proces dla publikacji publicznej; nie deklarować gotowej ochrony na podstawie filtrów klienta.

Przyjęty kierunek to CloudKit dla danych oraz dodatkowa usługa ograniczająca odczyt mapy/czatu. Najpierw badamy darmowe limity i prototyp; nie wybrano jeszcze docelowego wdrożenia i nie uruchomiono płatności. Chronione typy nie mogą mieć bocznej ścieżki odczytu bezpośrednio przez klienta. Pozostałe szczegóły tożsamości, moderacji i retencji wymagają implementacji i testów.

## Dokumentacja

- [Model baz i uprawnień Apple](https://developer.apple.com/icloud/cloudkit/designing/)
- [Konfiguracja CloudKit w aplikacji](https://developer.apple.com/documentation/cloudkit/enabling_cloudkit_in_your_app)
- [Wymagania konta iCloud](https://developer.apple.com/documentation/cloudkit/ckdatabase)
