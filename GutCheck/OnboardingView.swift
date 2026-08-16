import SwiftUI
import PhotosUI

// MARK: - W1: first-run onboarding. One job — get the household in.

struct OnboardingFlow: View {
    @EnvironmentObject var store: AppStore
    @State private var showAddPet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Text("🐕  🐈  🦮")
                    .font(.system(size: 44))
                Text("Scoop")
                    .font(.largeTitle.weight(.bold))
                Text("The health record for a house full of animals. Log what comes out, catch what caused it, and hand your vet a summary that makes sense.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer()

                if !store.data.pets.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(store.data.pets) { pet in
                            HStack(spacing: 12) {
                                PetAvatar(pet: pet, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pet.name)
                                        .font(.headline)
                                    Text(pet.breed.isEmpty ? pet.species.rawValue : pet.breed)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Tier.normal.color)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: DS.radius).fill(DS.surface))
                        }
                    }
                    .padding(.horizontal)
                }

                VStack(spacing: 12) {
                    if store.data.pets.isEmpty {
                        Button {
                            showAddPet = true
                        } label: {
                            Text("Add your first animal")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            showAddPet = true
                        } label: {
                            Text("Add another animal")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                    }

                    if !store.data.pets.isEmpty {
                        Button {
                            store.completeOnboarding()
                        } label: {
                            Text("That's the household, let's go")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Just looking? Load a demo household") {
                            store.resetToSeed()
                            // Pretend animals stay on this phone.
                            CloudSync.shared.demoStarted()
                        }
                        .font(.footnote)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .sheet(isPresented: $showAddPet) {
                AddPetSheet()
            }
        }
    }
}

// MARK: - Add an animal (name, species, breed, photo)

struct AddPetSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var species: Species = .dog
    @State private var breed = ""
    @State private var avatar = Species.dog.defaultAvatar
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var showBreedPicker = false
    @State private var hasBirthday = false
    @State private var birthdate = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        VStack(spacing: 8) {
                            if let photoData, let image = UIImage(data: photoData) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 96, height: 96)
                                    .clipShape(Circle())
                            } else {
                                ZStack {
                                    Circle()
                                        .fill(Color(.secondarySystemBackground))
                                        .frame(width: 96, height: 96)
                                    Text(avatar)
                                        .font(.system(size: 44))
                                }
                            }
                            Label(photoData == nil ? "Add their best photo" : "Change photo", systemImage: "camera.fill")
                                .font(.subheadline.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
                .onChange(of: photoItem) { newItem in
                    Task {
                        photoData = try? await newItem?.loadTransferable(type: Data.self)
                    }
                }

                Section("Basics") {
                    TextField("Name", text: $name)
                    Picker("Species", selection: $species) {
                        ForEach(Species.allCases, id: \.self) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: species) { newValue in
                        breed = ""
                        avatar = newValue.defaultAvatar
                    }
                    Button {
                        showBreedPicker = true
                    } label: {
                        HStack {
                            Text("Breed")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(breed.isEmpty ? "Choose" : breed)
                                .foregroundColor(breed.isEmpty ? .secondary : .accentColor)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    BirthdayRow(hasBirthday: $hasBirthday, birthdate: $birthdate)
                }

                if photoData == nil {
                    Section("Or pick an avatar") {
                        FlowLayout(spacing: 8) {
                            ForEach(species.avatarOptions, id: \.self) { option in
                                Chip(label: option, isSelected: avatar == option, tint: .accentColor) {
                                    avatar = option
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Text("Add to the household")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("New animal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showBreedPicker) {
                BreedPicker(species: species, selection: $breed)
            }
        }
    }

    private func save() {
        let photoFilename = photoData.map { store.savePhoto($0) }
        let pet = Pet(name: name.trimmingCharacters(in: .whitespaces),
                      species: species,
                      breed: breed,
                      avatar: avatar,
                      photoFilename: photoFilename,
                      birthdate: hasBirthday ? birthdate : nil)
        store.addPet(pet)
        dismiss()
    }
}

/// Birthday is optional — a tap reveals the picker instead of defaulting to today.
struct BirthdayRow: View {
    @Binding var hasBirthday: Bool
    @Binding var birthdate: Date

    var body: some View {
        if hasBirthday {
            DatePicker("Birthday", selection: $birthdate, in: ...Date(), displayedComponents: .date)
        } else {
            Button {
                hasBirthday = true
            } label: {
                HStack {
                    Text("Birthday")
                        .foregroundColor(.primary)
                    Spacer()
                    Text("Add")
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Breed selection

struct BreedPicker: View {
    let species: Species
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var matches: [String] {
        guard !search.isEmpty else { return species.commonBreeds }
        return species.commonBreeds.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !search.isEmpty && !matches.contains(where: { $0.caseInsensitiveCompare(search) == .orderedSame }) {
                    Button {
                        selection = search
                        dismiss()
                    } label: {
                        Label("Use \"\(search)\"", systemImage: "plus.circle")
                    }
                }
                ForEach(matches, id: \.self) { breed in
                    Button {
                        selection = breed
                        dismiss()
                    } label: {
                        HStack {
                            Text(breed)
                                .foregroundColor(.primary)
                            Spacer()
                            if breed == selection {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search breeds")
            .navigationTitle("Breed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

extension Species {
    var defaultAvatar: String {
        switch self {
        case .dog: return "🐶"
        case .cat: return "🐈"
        }
    }

    var avatarOptions: [String] {
        switch self {
        case .dog: return ["🐶", "🐕", "🦮", "🐕‍🦺", "🐩", "🐺"]
        case .cat: return ["🐈", "🐈‍⬛", "🐱"]
        }
    }

    var commonBreeds: [String] {
        switch self {
        case .dog:
            return [
                "Australian Shepherd", "Beagle", "Bernese Mountain Dog", "Border Collie",
                "Boston Terrier", "Boxer", "Cattle Dog (Heeler)", "Cavalier King Charles Spaniel",
                "Chihuahua", "Cocker Spaniel", "Corgi", "Dachshund", "Doberman",
                "English Bulldog", "French Bulldog", "German Shepherd", "Golden Retriever",
                "Goldendoodle", "Great Dane", "Great Pyrenees", "Havanese", "Jack Russell Terrier",
                "Labradoodle", "Labrador Retriever", "Maltese", "Miniature Schnauzer",
                "Mixed breed", "Pit Bull / AmStaff", "Pomeranian", "Poodle", "Pug",
                "Rottweiler", "Shiba Inu", "Shih Tzu", "Siberian Husky", "Yorkshire Terrier",
            ]
        case .cat:
            return [
                "Abyssinian", "Bengal", "British Shorthair", "Domestic Longhair",
                "Domestic Shorthair", "Maine Coon", "Mixed breed", "Persian", "Ragdoll",
                "Russian Blue", "Scottish Fold", "Siamese", "Siberian", "Sphynx",
            ]
        }
    }
}
