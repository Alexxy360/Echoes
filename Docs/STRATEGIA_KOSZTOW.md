# Strategia kosztów i rozwoju Echoes

Data: 12 listopada 2026. Kierunek właściciela: pierwsza wersja bez dodatkowych opłat za usługi; ewentualne płatne rozszerzenia po ocenie przychodów i potrzeb. Nie stanowi to zgody na uruchomienie płatności ani zmianę uprawnień do danych.

## Budżet na start

Przyjmujemy 0 zł dodatkowych opłat za hosting, bazę, przechowywanie plików i usługi zewnętrzne. Istniejące członkostwo Apple Developer jest osobnym kosztem właściciela i wymaga dalszego odnawiania. Nie uruchamiamy Blaze, płatnego backendu, automatycznego upgrade ani płatnych API bez konkretnej zgody właściciela. Warunki dostawcy i limity sprawdzamy przed uruchomieniem.

CloudKit korzysta z usług objętych istniejącym członkostwem Apple. Nie obiecujemy nielimitowanych operacji, ruchu ani całej przyszłej funkcjonalności bez dodatkowych kosztów. Pierwsza wersja musi mieścić się w możliwościach wybranej usługi i przejść odbiór.

## Zakres pierwszej wersji

Przygotować wersję minimalną na CloudKit z ograniczonym wolumenem zdjęć, miniaturami, stronicowaniem i cache. Trwały profil oddzielić od często zmieniającej się obecności. Konkretne funkcje dopasować do specyfikacji właściciela i wyników CK-01; zaawansowane obliczenia lub funkcje wymagające dodatkowej usługi można odłożyć.

Budżet 0 zł nie oznacza zgody na upublicznienie rekordów, usunięcie kontroli dostępu, publikację bez procesu moderacji ani udawanie serwerowych ograniczeń przez UI. Jeśli wymagana ochrona nie mieści się w bezpłatnym wariancie, przedstawiamy konkretny kompromis albo odkładamy daną funkcję. Zgłaszanie, blokowanie, kontakt wsparcia i rzeczywista obsługa zgłoszeń pozostają elementem odbioru przed publiczną dystrybucją; ręczna obsługa również wymaga pracy właściciela.

## Rozbudowa po uzyskaniu przychodów

Nie ma jednego zakupu, który odblokuje cały backend CloudKit. Gdy będzie potrzeba, można dodać konkretną zaufaną usługę do moderacji, retencji lub innej logiki. Nie musi to oznaczać wymiany całej bazy. Konkretny dostawca, koszt i zakres są wtedy osobną decyzją.

Aby umożliwić późniejszą rozbudowę:

- utrzymywać interfejsy oddzielające widoki i logikę od dostawcy danych;
- stosować stabilne identyfikatory aplikacji i jawne powiązanie z tożsamością dostawcy, bez zakładania ich zamienności;
- wersjonować schematy i przewidywać czytanie danych poprzedniej wersji;
- mieć plan eksportu, transformacji, sprawdzenia kompletności i usunięcia starych kopii, jeśli migracja danych okaże się potrzebna;
- rozdzielać profile, obecność, pliki, wiadomości oraz relacje;
- przed przełączeniem sprawdzić uprawnienia i zgodność starszych klientów.

Późniejsze dodanie warstwy serwerowej nadal wymaga pracy, testów i aktualizacji klienta. Dane wcześniej upublicznione nie stają się retroaktywnie prywatne i nie można cofnąć cudzych kopii.

## Kiedy wrócić do decyzji

Monitorować aktywnych użytkowników, operacje, transfer, throttling, opóźnienia i nakład moderacji. Przychód to jeden z warunków, ale aplikacja może stać się popularna przed osiągnięciem zysku. Wtedy można optymalizować, ograniczyć funkcję lub tempo testów zamiast automatycznie kupować usługę.

Przed uruchomieniem nowej płatnej usługi: konkretna potrzeba, szacunek obciążenia, cennik, akceptowalny budżet, sposób kontroli kosztu i zgoda właściciela.

## Stan migracji

Strategia nie kończy CK-01 ani nie zatwierdza wariantu dostępu A/B. Rejestracja App ID nadal oczekuje na zgodę na konkretny zapis w Apple Developer; istniejący program Apple i Bundle ID projektu nie zastępują tej rejestracji.

Źródła: [CloudKit w członkostwie Apple](https://developer.apple.com/programs/whats-included/), [ograniczanie żądań CloudKit](https://developer.apple.com/documentation/technotes/tn3162-understanding-cloudkit-throttles).
