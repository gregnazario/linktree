/// An example Linktree module
module lt_address::linktree {

    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::object::{Self, DeleteRef, ExtendRef};

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// Controller for the linktree object, to allow for extending and deletion
    struct Controller has key {
        extend_ref: ExtendRef,
        delete_ref: DeleteRef,
    }

    // TODO: add avatar via NFTs
    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// A bio for the account, extendable to add new fields
    enum Bio has key, copy, drop {
        V1 {
            name: String,
            bio: String,
            avatar_url: String,
        }
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// A linktree for the account, extendable to use different storage mechanisms
    enum LinkTree has key, drop {
        V1 {
            links: SimpleMap<String, Link>,
        },
    }

    // TODO: add special social links
    /// A link for the linktree, extendable to have more info later
    enum Link has store, copy, drop {
        V1 {
            url: String,
        }
    }

    /// A ref to ensure we can have a deletable linktree, with uniqueness
    /// TODO: Make an enum too?
    struct LinkTreeRef has key, copy, drop {
        object_address: address
    }

    /// Linktree already exists for user
    const E_LINKTREE_EXISTS: u64 = 1;

    /// Linktree doesn't exist for user
    const E_LINKTREE_DOESNT_EXIST: u64 = 2;

    /// Length of names and links don't match
    const E_INPUT_MISMATCH: u64 = 3;

    /// Creates an unordered linktree
    public entry fun create_v1(
        caller: &signer,
        names: vector<String>,
        links: vector<String>
    ) {
        let caller_address = signer::address_of(caller);
        assert!(!linktree_exists(caller_address), E_LINKTREE_EXISTS);

        let const_ref = object::create_object(caller_address);
        // Disable transfer and drop the ref
        {
            let transfer_ref = object::generate_transfer_ref(&const_ref);
            object::disable_ungated_transfer(&transfer_ref);
        };

        // TODO: These should be self functions...
        let extend_ref = object::generate_extend_ref(&const_ref);
        let delete_ref = object::generate_delete_ref(&const_ref);
        let object_signer = object::generate_signer(&const_ref);
        let object_address = object::address_from_constructor_ref(&const_ref);

        let annotated_links = links.map(|link| Link::V1 { url: link });
        let map = simple_map::new();
        map.add_all(names, annotated_links);

        move_to(&object_signer, Controller { extend_ref, delete_ref });
        move_to(&object_signer, LinkTree::V1 { links: map });
        move_to(caller, LinkTreeRef { object_address });
    }

    public entry fun add_links_v1(
        caller: &signer,
        names: vector<String>,
        links: vector<String>
    ) acquires LinkTreeRef, LinkTree {
        let num_names = names.length();
        let num_links = links.length();
        assert!(num_names == num_links, E_INPUT_MISMATCH);

        let caller_address = signer::address_of(caller);
        let maybe_linktree_address = get_linktree_address(caller_address);
        assert!(maybe_linktree_address.is_some(), E_LINKTREE_DOESNT_EXIST);

        let linktree_address = maybe_linktree_address.destroy_some();
        let annotated_links = links.map(|link| Link::V1 { url: link });
        let linktree = borrow_global_mut<LinkTree>(linktree_address);
        linktree.links.add_all(names, annotated_links);
    }

    public entry fun remove_links_v1(
        caller: &signer,
        names: vector<String>
    ) acquires LinkTreeRef, LinkTree {
        let caller_address = signer::address_of(caller);
        let maybe_linktree_address = get_linktree_address(caller_address);
        assert!(maybe_linktree_address.is_some(), E_LINKTREE_DOESNT_EXIST);

        let linktree_address = maybe_linktree_address.destroy_some();
        let linktree = borrow_global_mut<LinkTree>(linktree_address);
        names.for_each_ref(|name| {
            linktree.links.remove(name);
        });
    }

    public entry fun delete_linktree(caller: &signer) acquires LinkTreeRef, Bio, LinkTree, Controller {
        let caller_address = signer::address_of(caller);
        let maybe_linktree_address = get_linktree_address(caller_address);
        assert!(maybe_linktree_address.is_some(), E_LINKTREE_DOESNT_EXIST);

        let linktree_address = maybe_linktree_address.destroy_some();

        // Cleanup object
        move_from<Bio>(linktree_address);
        move_from<LinkTree>(linktree_address);
        let Controller {
            delete_ref,
            ..
        } = move_from<Controller>(linktree_address);
        object::delete(delete_ref);

        // Cleanup refernce to object
        move_from<LinkTreeRef>(caller_address);
    }

    #[view]
    public fun get_linktree_address(owner: address): Option<address> acquires LinkTreeRef {
        // Return nothing if there are no links
        if (!exists<LinkTreeRef>(owner)) {
            option::none()
        } else {
            option::some(borrow_global<LinkTreeRef>(owner).object_address)
        }
    }

    #[view]
    public fun linktree_exists(owner: address): bool {
        exists<LinkTreeRef>(owner)
    }

    #[view]
    /// This returns the bio for the account, and will abort if there is no linktree
    public fun view_bio(owner: address): Bio acquires LinkTreeRef, Bio {
        let maybe_linktree_address = get_linktree_address(owner);
        assert!(maybe_linktree_address.is_some(), E_LINKTREE_DOESNT_EXIST);

        let linktree_address = maybe_linktree_address.destroy_some();
        *borrow_global<Bio>(linktree_address)
    }

    #[view]
    /// View the links for the linktree.  This is returned as two vectors so it can be ordered
    public fun view_links(owner: address): simple_map::SimpleMap<String, Link> acquires LinkTreeRef, LinkTree {
        // Return nothing if there are no links
        if (!exists<LinkTreeRef>(owner)) {
            return simple_map::new()
        };

        let object_address = borrow_global<LinkTreeRef>(owner).object_address;
        borrow_global<LinkTree>(object_address).links
    }
}