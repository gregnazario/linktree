/// Aptos Profile
module lt_address::profile {

    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::object::{Self, DeleteRef, ExtendRef, Object};
    use aptos_token_objects::token::Token;

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// Controller for the linktree object, to allow for extending and deletion
    struct Controller has key {
        extend_ref: ExtendRef,
        delete_ref: DeleteRef
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// A bio for the account, extendable to add new fields
    enum Bio has key, copy, drop {
        /// URL given for an image
        Image {
            name: String,
            bio: String,
            avatar_url: String
        }
        /// NFT locked up for an image
        NFT {
            name: String,
            bio: String,
            avatar_nft: Object<Token>
        }
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// A linktree for the account, extendable to use different storage mechanisms
    enum LinkTree has key, copy, drop {
        /// Simple map implementation
        SM {
            links: SimpleMap<String, Link>
        }
    }

    /// A link for the linktree, extendable to have more info later
    enum Link has store, copy, drop {
        /// Unordered links, no other info
        UnorderedLink {
            url: String
        }
    }

    /// A ref to ensure we can have a deletable profile, with uniqueness
    struct ProfileRef has key, copy, drop {
        object_address: address
    }

    /// Linktree already exists for user
    const E_LINKTREE_EXISTS: u64 = 1;

    /// Linktree doesn't exist for user
    const E_LINKTREE_DOESNT_EXIST: u64 = 2;

    /// Length of names and links don't match
    const E_INPUT_MISMATCH: u64 = 3;

    /// Image URL and NFT can't both be given, only one or the other
    const E_IMAGE_AND_NFT: u64 = 4;

    /// Creates an unordered linktree
    public entry fun create(
        caller: &signer,
        name: String,
        bio: String,
        avatar_url: Option<String>,
        avatar_nft: Option<Object<Token>>,
        names: vector<String>,
        links: vector<String>
    ) {
        let caller_address = signer::address_of(caller);
        assert!(!linktree_exists(caller_address), E_LINKTREE_EXISTS);

        assert!(
            (avatar_url.is_none()
                || avatar_nft.is_none())
                && (avatar_url.is_some()
                    || avatar_nft.is_some()),
            E_IMAGE_AND_NFT
        );

        let object_signer = create_object(caller_address);

        // If it's an NFT, lock it up for usage, otherwise use an image
        if (avatar_nft.is_some()) {
            let nft = avatar_nft.destroy_some();
            connect_nft(caller, nft);
            move_to(
                &object_signer,
                Bio::NFT { name, bio, avatar_nft: nft }
            )
        } else if (avatar_url.is_some()) {
            move_to(
                &object_signer,
                Bio::Image { name, bio, avatar_url: avatar_url.destroy_some() }
            );
        };

        let names_length = names.length();
        let links_length = links.length();
        assert!(names_length == links_length, E_INPUT_MISMATCH);

        let converted_links = convert_links(links);
        let map = simple_map::new();
        map.add_all(names, converted_links);

        move_to(&object_signer, LinkTree::SM { links: map });
        move_to(caller, ProfileRef { object_address: signer::address_of(&object_signer) });
    }

    /// Creates an untransferrable object
    fun create_object(owner_address: address): signer {
        let const_ref = object::create_object(owner_address);
        // Disable transfer and drop the ref
        {
            let transfer_ref = object::generate_transfer_ref(&const_ref);
            object::disable_ungated_transfer(&transfer_ref);
        };

        // TODO: These should be self functions...
        let extend_ref = object::generate_extend_ref(&const_ref);
        let delete_ref = object::generate_delete_ref(&const_ref);
        let object_signer = object::generate_signer(&const_ref);

        move_to(&object_signer, Controller { extend_ref, delete_ref });
        object_signer
    }

    /// Converts string links to Link type
    fun convert_links(links: vector<String>): vector<Link> {
        let converted = vector[];
        for (i in 0..links.length()) {
            converted.push_back(Link::UnorderedLink { url: links[i] });
        };

        converted
    }

    /// Connects an NFT to the account
    fun connect_nft(owner: &signer, avatar_nft: Object<Token>) {
        // Create an object, that no one can move or control
        let object_signer = create_object(@0x0);
        object::transfer(owner, avatar_nft, signer::address_of(&object_signer));
    }

    /// Destroys a bio object
    fun destroy_bio(owner: address, bio: Bio) acquires Controller {
        match(bio) {
            Bio::Image { name: _, bio: _, avatar_url: _ } => {}
            Bio::NFT { name: _, bio: _, avatar_nft } => {
                // Transfer the NFT back to the original user
                let holder = object::owner(avatar_nft);
                let Controller { extend_ref, delete_ref } = move_from<Controller>(holder);
                let object_signer = object::generate_signer_for_extending(&extend_ref);
                object::transfer(&object_signer, avatar_nft, owner);

                // Then delete the holding object
                object::delete(delete_ref)
            }
        }
    }

    /// Add a set of links
    public entry fun add_links(
        caller: &signer, names: vector<String>, links: vector<String>
    ) acquires ProfileRef, LinkTree {
        let num_names = names.length();
        let num_links = links.length();
        assert!(num_names == num_links, E_INPUT_MISMATCH);

        let caller_address = signer::address_of(caller);
        let maybe_linktree_address = get_linktree_address(caller_address);
        assert!(maybe_linktree_address.is_some(), E_LINKTREE_DOESNT_EXIST);

        let linktree_address = maybe_linktree_address.destroy_some();
        let annotated_links = convert_links(links);
        let linktree = borrow_global_mut<LinkTree>(linktree_address);
        for (i in 0..num_names) {
            linktree.links.upsert(names[i], annotated_links[i])
        };
    }

    /// Remove a set of links
    public entry fun remove_links(caller: &signer, names: vector<String>) acquires ProfileRef, LinkTree {
        let caller_address = signer::address_of(caller);
        let maybe_linktree_address = get_linktree_address(caller_address);
        assert!(maybe_linktree_address.is_some(), E_LINKTREE_DOESNT_EXIST);

        let linktree_address = maybe_linktree_address.destroy_some();
        let linktree = borrow_global_mut<LinkTree>(linktree_address);
        names.for_each_ref(|name| {
            linktree.links.remove(name);
        });
    }

    /// Delete the Linktree and return the NFTs if any
    public entry fun delete_linktree(caller: &signer) acquires ProfileRef, Bio, LinkTree, Controller {
        let caller_address = signer::address_of(caller);
        let maybe_linktree_address = get_linktree_address(caller_address);
        assert!(maybe_linktree_address.is_some(), E_LINKTREE_DOESNT_EXIST);

        let linktree_address = maybe_linktree_address.destroy_some();

        // Cleanup object
        let bio = move_from<Bio>(linktree_address);
        destroy_bio(caller_address, bio);
        move_from<LinkTree>(linktree_address);
        let Controller { delete_ref,.. } = move_from<Controller>(linktree_address);
        object::delete(delete_ref);

        // Cleanup refernce to object
        move_from<ProfileRef>(caller_address);
    }

    #[view]
    public fun get_linktree_address(owner: address): Option<address> acquires ProfileRef {
        // Return nothing if there are no links
        if (!exists<ProfileRef>(owner)) {
            option::none()
        } else {
            option::some(borrow_global<ProfileRef>(owner).object_address)
        }
    }

    #[view]
    public fun linktree_exists(owner: address): bool {
        exists<ProfileRef>(owner)
    }

    #[view]
    /// This returns the bio for the account, and will abort if there is no linktree
    public fun view_bio(owner: address): Option<Bio> acquires ProfileRef, Bio {
        get_linktree_address(owner).map(|linktree_address| *borrow_global<Bio>(
            linktree_address
        ))
    }

    #[view]
    /// View the links for the linktree.  This is returned as two vectors so it can be ordered
    public fun view_links(owner: address): LinkTree acquires ProfileRef, LinkTree {
        let maybe_linktree_address = get_linktree_address(owner);
        if (maybe_linktree_address.is_none()) {
            // Return nothing if there are no links
            LinkTree::SM { links: simple_map::new() }
        } else {
            *borrow_global<LinkTree>(maybe_linktree_address.destroy_some())
        }
    }
}
