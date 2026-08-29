## The app's voice.
##
## Moses at Horeb, in the register of a machine that will outlive you: Exodus
## for the covenant, TempleOS for the delivery, and just enough of a man who
## announced in advance that if he was found dead he had not done it himself.
##
## Kept in one place because the tone has to hold. Everything the app says to
## the keeper comes from here.

class_name Scripture
extends RefCounted


## Shown under the bush, according to the flame's state.
static func state_verse(state: Flame.State) -> String:
	match state:
		Flame.State.BURNING:
			return "THE BUSH BURNS AND IS NOT CONSUMED."
		Flame.State.GUTTERING:
			return "THE FLAME GUTTERS. TEND IT, OR THE WORD GOES OUT."
		Flame.State.DARK:
			return "THE FLAME IS DARK. LET MY PEOPLE GO."
		Flame.State.NEVER_LIT:
			return "NO FIRE ON THIS MOUNTAIN YET."
		_:
			return "THE MOUNTAIN IS SILENT. NO ANSWER FROM THE CHAIN."


## Longer gloss under the verse.
static func state_gloss(state: Flame.State, days_left: int) -> String:
	match state:
		Flame.State.BURNING:
			if days_left == 1:
				return "One day until the flame gutters."
			return "%d days until the flame gutters." % maxi(days_left, 0)
		Flame.State.GUTTERING:
			if days_left <= 0:
				return "The grace has run out. The covenant may be opened."
			return "%d days of grace remain. Tend the flame." % days_left
		Flame.State.DARK:
			return "The witnesses may gather their fragments and open the tablet."
		Flame.State.NEVER_LIT:
			return "Kindle the flame to begin. Nothing is watched until you do."
		_:
			return "Could not read the flame. This says nothing about the keeper."


## TempleOS-style oracle, drawn at random. Terry pulled words from a dictionary
## and read God in the result; these are hand-picked, which is cheating, but the
## machine is not going to know the difference.
const ORACLE := [
	"PUT OFF THY SHOES. THIS IS HOLY GROUND.",
	"I AM THAT I AM.",
	"WHAT IS THAT IN THINE HAND?",
	"A PILLAR OF FIRE BY NIGHT.",
	"HEW THEE TWO TABLES OF STONE, LIKE UNTO THE FIRST.",
	"THE WORD KEEPS. THE KEEPER DOES NOT.",
	"640x480. 16 COLORS. NO EXCUSES.",
	"AN OFFERING MUST COST SOMETHING.",
	"IF I SUICIDE MYSELF, I DIDN'T.",
	"THE CHAIN DOES NOT FORGET, AND CANNOT BE ASKED TO.",
	"WRITE IT AS THOUGH IT CANNOT BE UNWRITTEN. IT CANNOT.",
	"A DEAD MAN'S HAND IS STILL A HAND.",
	"THE BUSH BURNED, AND WAS NOT CONSUMED.",
	"SPEAK NOW, OR HAVE IT SPOKEN FOR YOU.",
	"NOTHING HERE ASKS PERMISSION TO REMEMBER.",
	"HE WHO TENDS THE FIRE IS NOT THE FIRE.",
]


static func oracle(rng: RandomNumberGenerator = null) -> String:
	if rng == null:
		return ORACLE[randi() % ORACLE.size()]
	return ORACLE[rng.randi() % ORACLE.size()]


## Shown before the keeper commits something irreversible.
static func sealing_warning(witnesses: int, threshold: int) -> String:
	return (
		"This cannot be undone.\n\n"
		+ "The tablet becomes public the moment it is inscribed. It cannot be "
		+ "edited, deleted, or recalled — not by you, not by anyone.\n\n"
		+ "Its contents stay shut only while fewer than %d of the %d fragments "
		+ "are brought together. Give one fragment to each witness, keep none "
		+ "yourself, and do not write the key down.\n\n"
		+ "Never seal another person's private matters. There is no unpublish."
	) % [threshold, witnesses]


## Shown to a witness when the flame has gone dark.
static func witness_summons(keeper: String, threshold: int) -> String:
	return (
		"The flame kept by %s has gone dark.\n\n"
		+ "You hold one fragment. %d must be brought together to open the "
		+ "tablet. Nothing happens until they are."
	) % [keeper, threshold]


## Names for the fragment count, because "n-of-m" reads like a spreadsheet.
static func threshold_phrase(threshold: int, witnesses: int) -> String:
	return "any %d of %d witnesses" % [threshold, witnesses]
