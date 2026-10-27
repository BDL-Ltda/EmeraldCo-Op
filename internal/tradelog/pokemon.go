package tradelog

import (
	"encoding/binary"
	"encoding/hex"
)

// Struct offsets and the substructure permutation are sourced in
// docs/memory-map.md#pokemon-bytes-in-the-trade-log, not live memory addresses.
const (
	pokemonSize       = 100
	personalityOffset = 0
	otIDOffset        = 4
	checksumOffset    = 28
	secureOffset      = 32
	secureSize        = 48
	substructSize     = 12
)

// GetSubstruct(personality, 0) in the pinned ROM's src/pokemon.c.
var growthPositions = [...]int{0, 0, 0, 0, 0, 0, 1, 1, 2, 3, 2, 3,
	1, 1, 2, 3, 2, 3, 1, 1, 2, 3, 2, 3}

func describePokemon(encoded string) (uint16, string, bool) {
	data, err := hex.DecodeString(encoded)
	if err != nil || len(data) != pokemonSize {
		return 0, "UNKNOWN", false
	}
	personality := binary.LittleEndian.Uint32(data[personalityOffset:])
	key := personality ^ binary.LittleEndian.Uint32(data[otIDOffset:])
	secure := data[secureOffset : secureOffset+secureSize]
	for offset := 0; offset < len(secure); offset += 4 {
		word := binary.LittleEndian.Uint32(secure[offset:]) ^ key
		binary.LittleEndian.PutUint32(secure[offset:], word)
	}
	var checksum uint16
	for offset := 0; offset < len(secure); offset += 2 {
		checksum += binary.LittleEndian.Uint16(secure[offset:])
	}
	species := binary.LittleEndian.Uint16(secure[growthPositions[personality%24]*substructSize:])
	name := "UNKNOWN"
	if int(species) < len(speciesNames) {
		name = speciesNames[species]
	}
	return species, name, checksum == binary.LittleEndian.Uint16(data[checksumOffset:])
}
