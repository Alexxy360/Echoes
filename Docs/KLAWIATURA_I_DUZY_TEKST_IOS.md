# UI-01 — klawiatura i największy tekst

Przy przewijaniu ustawień na iOS 26.1 pojawiał się komunikat `Invalid frame dimension (negative or non-finite)`. Testy mogły przechodzić mimo ostrzeżenia. Krótki scenariusz ustawień odtworzył je przed otwarciem edytora zdjęcia.

Bezpośredni breakpoint LLDB zarejestrował `_FrameLayout.init(width:height:alignment:)` wywołane z `InputAccessoryBar.body`. To wskazuje ścieżkę powstania ostrzeżenia, a nie ujawnia wewnętrznych obliczeń iOS. Pasek był tworzony przez `ToolbarItemGroup(placement: .keyboard)`. Wariant warunkowy, dostępny tylko podczas edycji pseudonimu, usunął ostrzeżenie przy przewijaniu; nadal zgłaszał je przy otwieraniu klawiatury.

## Zmiana

Ustawienia, ekran wejścia i czat używają teraz wspólnego `KeyboardDismissControl` w dolnym `safeAreaInset`, widocznego podczas aktywnej edycji. Wysokość wynika z treści i wybranego rozmiaru pisma. Przycisk pozostaje nad klawiaturą i zamyka fokus, zachowując pseudonim albo szkic. Pseudonim ma również systemową etykietę klawisza Gotowe; wielowierszowy czat zachowuje wprowadzanie nowego wiersza.

Istniejące identyfikatory dostępności przycisków są zachowane. Usunięto trzy grupy akcesoriów klawiatury. Komponent ma izolowane podglądy zwykłego i największego tekstu; jego faktyczny układ sprawdzają testy aplikacji.

Znaczenie użytych API opisuje Apple: [safeAreaInset](https://developer.apple.com/documentation/swiftui/view/safeareainset(edge:alignment:spacing:content:)-6gwby), [submitLabel](https://developer.apple.com/documentation/swiftui/view/submitlabel(_:)).

Zrzuty największego tekstu: [ustawienia](evidence/keyboard-ui/settings-keyboard-ax.png), [czat](evidence/keyboard-ui/chat-keyboard-ax.png), [wejście](evidence/keyboard-ui/onboarding-keyboard-ax.png).

## Dowody i zakres

[Raport testów](evidence/keyboard-safe-area-local-tests.json) zapisuje rzeczywiste przebiegi, istotne symbole stosu oraz SHA źródeł, logów i zrzutów. Wstępne próby ogólnego przechwytywania logów nie dały źródła; jedna późniejsza komenda została przerwana podczas zawieszonego zbierania sysdiagnose po zakończeniu asercji. Nie jest liczona jako zakończony odbiór. Następna próba z gotowym breakpointem uzyskała stos. Dalsze krótkie testy używały `-collect-test-diagnostics never`; raportowanie ostrzeżeń i wyników pozostało aktywne.

Testy używają prawdziwego SwiftUI i klawiatury symulatora iPhone 17 Pro z iOS 26.1, syntetycznych tożsamości i modeli usług. Nie są odbiorem VoiceOver, sprzętowej klawiatury, innego systemu, fizycznego telefonu ani rzeczywistego CloudKit. Poprawka nie zmienia pakietów domenowych, backendu, aktywacji usług lub konfiguracji Xcode. Pozostałe wymagania migracji i TestFlight nadal obowiązują.

Końcowa walidacja: **11 różnych scenariuszy UI zaliczonych, bez ostrzeżeń runtime** — główna regresja 10/10 oraz osobny zapis pseudonimu z konfliktem 1/1. Cztery nowe funkcje sprawdzają dostęp do zdjęcia w ustawieniach oraz klawiaturę ustawień, czatu i wejścia przy największym tekście. Debug, niepodpisany Release i strict format siedmiu plików są poprawne. Historia wcześniejszych ostrzeżeń pozostaje w poprzednich raportach; ten wynik dotyczy wskazanych scenariuszy na jednym systemie symulatora.
