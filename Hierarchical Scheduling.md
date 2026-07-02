# **Hierarchical Scheduling**

## **Motivation**

This work was initiated when the author wanted to run ‘make \-j’ on a Linux machine, without making the machine unresponsive for interactive tasks and at the same time have good CPU utilization.

## **Scheduling**

The scheduler has a number of entities (processes) in a queue to schedule on execution resources (a number of processors). Here, each entity corresponds to a single process or a collection of processes (for example, all processes belonging to a user). Each process may be executing or blocked. It may be blocked involuntarily \- waiting for processor execution (ready) \- or voluntarily \- usually waiting for or other resources (blocked). The main task of the scheduling policy is, if the number of entities ready to execute in the queue are more than the number of processors, to select which entities that are given execution resources.

Scheduling may be cooperative or preemptive. If it is possible to preempt entities, given uncooperative entities, the scheduler can always enforce its policy. Otherwise, some entities may be penalized by others. (Unless uncooperative behaviour is detected and the corresponding entity is killed immediately \- replacing preemption.)

The basic scheduling policy is priority based, from which additional polices may be derived.

Priority based scheduling maintains an order (which may or may not be mapped onto priority numbers) for its queue of entities, and entities are scheduled in that order. I.e. the task of the scheduler is to find the first entity ready for execution (excluding processes blocked for resources such as I/O) , searching in the queue order. (This means that low-priority entities may wait indefinitely to be scheduled.) If a high-priority process becomes unblocked, it may immediately preempt (block) a process with lower priority. Here, we will use a strict total order to make the scheduling decision deterministic.

Priorities may be dynamic. An example is round-robin scheduling, where a circular queue is maintained, representing the strict total order. Each entity is limited by a time quantum. When the quantum ends, the entity is preempted and placed last in the queue. (This means that no entity may wait indefinitely to be scheduled.)

(Each entity may have its own quantum size. For example, there may be a small quantum (1000Hz) for user A, a somewhat larger quantum (100Hz) for user B, and an even larger for user C (10Hz). If all are entities are executed without any blockage, entity C utilize about 90%, entity B about 9%, and entity A about 1%, of the execution resources. If the other entities blocks, any single entity may utilize 100% of the execution resources.)

(If real-time properties are important, priority inheritance may be done. For example, if one entity blocks, it may, if possible, lend the current execution resources to the entity it waits for.)

## **Hierarchical Scheduling**

Scheduling may be nested (hierarchical). That is, a scheduling entity may either be a single process (leaf node) or a collection of sub-entities (tree node) encapsulated in a single scheduler queue, that share the resources given to the parent entity. The strict total order of the whole tree is defined according to the nesting and the order of the queue of each tree node, i.e. as a traversal of the tree. All time quanta encountered on a path to a leaf node, has to be applied (simultaneously).

For example, a system may at the top level consist of two scheduling entities: the operating system (interrupts) and user processes. The first have higher priority than the second. Then user processes are divided into a number of users, using a round-robin policy. One user may then divided its scheduling entity into processes with fixed priorities (similar to POSIX SCHED\_FIFO).

**Hierarchical scheduling is a useful abstraction, because, for example, if a user A starts processes scheduled with fixed priorities (similar to SCHED\_FIFO), then this is done *within* the scheduling entity given to user A. That is, it is invisible to other users (entities on the same level) what kind of scheduling A is using for its processes. Contrast this with SCHED\_FIFO in POSIX, which is system-wide (flat), and if a process is uncooperative, it may lock the whole system.**

In practice, to control scheduling, the user may define two scheduling polices, used when a new child process is created: a parent-child policy and a sibling policy. For example, fixed priorities may be used for the parent-child queue, the parent being the higher-priority process, while round-robin may be used for siblings. When a process creates its first child process, the child process is placed in a new sibling queue, which in turn is placed in a new parent-child queue together with the parent process. When subsequent child processes are created, they are placed in the sibling queue.

### **The ‘make \-j’ example**

The possibility for a user to use fixed priorities (without disrupting other users), was the main motivation for this work. **Using fixed priorities for all (CPU-intensive) processes started by ‘make \-j’ (for both the parent-child queue and the sibling queue mentioned above \- with new siblings placed last in the queue), should make it possible to start an unlimited number of processes, without trashing caches and therefore degrading the throughput (or responsiveness due to overload) of the system.** There will newer be more CPU-intensive processes “active” than the number of processors. If one of them blocks, waiting for I/O, a new process (if previously initiated by ‘make \-j’) is replacing the blocked process immediately. Reversely, when the blocked process unblocks, it preempts the new process. This makes it unnecessary to specify the maximum number of jobs; the system always runs as many it is able to execute simultaneously.